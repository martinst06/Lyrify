import Foundation

class LyricsViewModel: ObservableObject {
    @Published var lines: [LRCLine] = []
    @Published var activeIndex: Int = -1
    @Published var statusMessage: String = "Waiting for Spotify…"
    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var trackKey: String = ""
    @Published var isPlaying: Bool = false

    // Unsynced (plain-text) lyrics from LRCLIB-plain or Genius. Split into display lines so the
    // view can auto-scroll by line count; `plainProgress` (0...1) is the estimated playback
    // fraction the view maps onto those lines. Empty/`0` unless a plain result is showing.
    @Published var plainLyricLines: [String] = []
    @Published var plainProgress: Double = 0
    @Published var spotifyWarning: SpotifyLyricsWarning?

    // The background loops read these snapshots under `stateLock` instead of hopping onto
    // the main thread. `DispatchQueue.main.sync` on a 0.4s loop is a deadlock waiting to
    // happen; the snapshots stay in lock-step with the @Published values (see `setLines`/
    // `setActiveIndex`) so the loops always see the freshest state.
    private let stateLock = NSLock()
    private var currentKey = ""
    private var linesSnapshot: [LRCLine] = []
    private var activeIndexSnapshot = -1
    private var isPlayingSnapshot = false
    private var hasPlainSnapshot = false
    private var lastPreloadedKey = ""

    // Lyrics fetching blocks (up to the LRCLIB timeout). It runs on its own serial queue so
    // a slow or lyric-less song can never stall track-change detection or the position loop —
    // detection used to share this thread, so one slow fetch froze the whole app.
    private let fetchQueue = DispatchQueue(label: "lyrify.fetch")

    init() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.trackLoop() }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.positionLoop() }
    }

    // ── Track change loop (detection only — never blocks on the network) ──────

    private func trackLoop() {
        while true {
            // Each iteration in its own pool: this loop never returns, so without an explicit
            // pool the autoreleased Process/Pipe/Data objects from the osascript calls would
            // pile up forever (fd + memory leak) and eventually wedge the app.
            autoreleasepool { checkTrack() }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func checkTrack() {
        guard let info = SpotifyBridge.getTrackInfo() else {
            stateLock.lock(); let had = !currentKey.isEmpty; if had { currentKey = "" }; stateLock.unlock()
            if had {
                setLines([])
                setPlain(nil)
                main {
                    self.trackKey = ""
                    self.statusMessage = "Waiting for Spotify…"
                }
            }
            return
        }

        let key = info.identity
        stateLock.lock(); let changed = key != currentKey; if changed { currentKey = key }; stateLock.unlock()
        guard changed else { return }

        setLines([])
        setActiveIndex(-1)
        setPlain(nil)
        main {
            self.trackTitle = info.title
            self.trackArtist = info.artist
            self.trackKey = key
            self.statusMessage = "Loading…"
        }

        // Hand the blocking fetch to the worker; detection keeps polling at 0.8s.
        fetchQueue.async { [weak self] in self?.fetchLyrics(for: info, key: key) }

        // Learn the next song from the Spotify Web API and warm its lyrics into the cache, so
        // the upcoming track change is an instant cache hit instead of a "Loading…" gap. Fully
        // optional: no client ID / auth / active device just means this is a no-op.
        preloadNextLyrics()
    }

    private func preloadNextLyrics() {
        SpotifyWebAPI.nextTrack { [weak self] next in
            guard let self = self, let next = next else { return }
            let key = "\(next.title)|\(next.artist)"
            self.stateLock.lock()
            let alreadyPreloaded = key == self.lastPreloadedKey
            if !alreadyPreloaded { self.lastPreloadedKey = key }
            self.stateLock.unlock()
            guard !alreadyPreloaded else { return }

            // Warm the cache; the result is discarded. Runs on the Web API queue, never the
            // detection loop, the position loop, or main.
            _ = LyricsService.fetchSync(trackId: next.trackId, title: next.title, artist: next.artist,
                                        album: next.album, durationMs: next.durationMs)
        }
    }

    private func fetchLyrics(for info: SpotifyTrackInfo, key: String) {
        // The track may have changed again before this fetch got its turn on the queue.
        guard isCurrent(key) else { return }

        let result = LyricsService.fetchSync(
            trackId: info.trackId, title: info.title, artist: info.artist,
            album: info.album, durationMs: info.durationMs,
            onEarlyPlain: { [weak self] plain in
                // Progressive display: show plain text the moment it's available, while the
                // synced version is still loading, instead of sitting on "Loading…".
                guard let self = self, self.isCurrent(key) else { return }
                self.stateLock.lock(); let hasSynced = !self.linesSnapshot.isEmpty; self.stateLock.unlock()
                guard !hasSynced else { return }
                self.setPlain(plain)
            }
        )

        // Not per-song, so publish it even if the track changed while fetching.
        let warning = SpotifyLyricsService.warning
        main { if self.spotifyWarning != warning { self.spotifyWarning = warning } }

        // fetchSync blocked for up to a few seconds. If the user skipped tracks while it was
        // in flight, the live track no longer matches what we fetched — drop the stale result
        // so we don't paint one song's lyrics over another.
        guard isCurrent(key) else { return }

        if let synced = result.synced {
            let parsed = LRCParser.parse(synced)
            if !parsed.isEmpty { setPlain(nil); setLines(parsed); return }
        }
        setLines([])
        if let plain = result.plain {
            setPlain(plain)
        } else {
            setPlain(nil)
            main { self.statusMessage = "No lyrics found." }
        }
    }

    private func isCurrent(_ key: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return key == currentKey
    }

    // ── Seek ───────────────────────────────────────────────────────────────

    /// Jump Spotify to a tapped lyric line. Updates the highlight immediately
    /// for instant feedback; the position loop reconciles once Spotify catches up.
    func seek(to line: LRCLine) {
        setActiveIndex(line.id)
        SpotifyBridge.seek(to: line.time)
    }

    // ── Position loop ────────────────────────────────────────────────────────

    private func positionLoop() {
        while true {
            autoreleasepool { updatePosition() }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func updatePosition() {
        guard let info = SpotifyBridge.getTrackInfo() else { return }

        stateLock.lock()
        let lines = linesSnapshot
        let current = activeIndexSnapshot
        let wasPlaying = isPlayingSnapshot
        let hasPlain = hasPlainSnapshot
        stateLock.unlock()

        // Reconcile play/pause every tick, even with no lyrics. This used to sit *after* the
        // empty-lines guard, so the button stuck on the wrong icon for lyric-less songs.
        if info.isPlaying != wasPlaying {
            stateLock.lock(); isPlayingSnapshot = info.isPlaying; stateLock.unlock()
            main { self.isPlaying = info.isPlaying }
        }

        // Synced lyrics: highlight the current line by timestamp.
        if !lines.isEmpty {
            var idx = -1
            for line in lines {
                if line.time <= info.position { idx = line.id } else { break }
            }
            if idx != current { setActiveIndex(idx) }
            return
        }

        // Plain (unsynced) lyrics: no timestamps, so publish the estimated playback fraction
        // and let the view auto-scroll. The value only moves while playing (position advances),
        // so scrolling naturally freezes on pause. Guard the write so a static value (paused)
        // doesn't churn the publisher and retrigger the view's scroll every tick.
        if hasPlain {
            let p = PlainScroll.progress(positionSec: info.position, durationMs: info.durationMs)
            main { if self.plainProgress != p { self.plainProgress = p } }
        }
    }

    // ── State setters: keep the @Published value (UI) and the snapshot (loops) in sync ──

    private func setLines(_ value: [LRCLine]) {
        stateLock.lock(); linesSnapshot = value; stateLock.unlock()
        main { self.lines = value }
    }

    /// Set (or clear, with `nil`) the plain-text lyrics. Splits into display lines, dropping
    /// blank lines at the top and bottom so the pace estimate maps onto real words, not empty
    /// padding. Clearing also resets `plainProgress` so a new song starts scrolled to the top.
    private func setPlain(_ text: String?) {
        var lines: [String] = []
        if let text = text {
            lines = text.components(separatedBy: .newlines)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        }
        stateLock.lock(); hasPlainSnapshot = !lines.isEmpty; stateLock.unlock()
        main {
            self.plainLyricLines = lines
            if lines.isEmpty { self.plainProgress = 0 }
        }
    }

    private func setActiveIndex(_ value: Int) {
        stateLock.lock(); activeIndexSnapshot = value; stateLock.unlock()
        main { self.activeIndex = value }
    }

    private func main(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
