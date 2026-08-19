import Foundation

class LyricsViewModel: ObservableObject {
    @Published var lines: [LRCLine] = []
    @Published var activeIndex: Int = -1
    @Published var statusMessage: String = "Waiting for Spotify…"
    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var isPlaying: Bool = false

    // The background loops read these snapshots under `stateLock` instead of hopping onto
    // the main thread. `DispatchQueue.main.sync` on a 0.4s loop is a deadlock waiting to
    // happen; the snapshots stay in lock-step with the @Published values (see `setLines`/
    // `setActiveIndex`) so the loops always see the freshest state.
    private let stateLock = NSLock()
    private var currentKey = ""
    private var linesSnapshot: [LRCLine] = []
    private var activeIndexSnapshot = -1
    private var isPlayingSnapshot = false
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
                main { self.statusMessage = "Waiting for Spotify…" }
            }
            return
        }

        let key = "\(info.title)|\(info.artist)"
        stateLock.lock(); let changed = key != currentKey; if changed { currentKey = key }; stateLock.unlock()
        guard changed else { return }

        setLines([])
        setActiveIndex(-1)
        main {
            self.trackTitle = info.title
            self.trackArtist = info.artist
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
            _ = LyricsService.fetchSync(title: next.title, artist: next.artist,
                                        album: next.album, durationMs: next.durationMs)
        }
    }

    private func fetchLyrics(for info: SpotifyTrackInfo, key: String) {
        // The track may have changed again before this fetch got its turn on the queue.
        guard isCurrent(key) else { return }

        let result = LyricsService.fetchSync(
            title: info.title, artist: info.artist,
            album: info.album, durationMs: info.durationMs,
            onEarlyPlain: { [weak self] plain in
                // Progressive display: show plain text the moment it's available, while the
                // synced version is still loading, instead of sitting on "Loading…".
                guard let self = self, self.isCurrent(key) else { return }
                self.main { if self.lines.isEmpty { self.statusMessage = plain } }
            }
        )

        // fetchSync blocked for up to a few seconds. If the user skipped tracks while it was
        // in flight, the live track no longer matches what we fetched — drop the stale result
        // so we don't paint one song's lyrics over another.
        guard isCurrent(key) else { return }

        if let synced = result.synced {
            let parsed = LRCParser.parse(synced)
            if !parsed.isEmpty { setLines(parsed); return }
        }
        setLines([])
        main { self.statusMessage = result.plain ?? "No lyrics found." }
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
        stateLock.unlock()

        // Reconcile play/pause every tick, even with no lyrics. This used to sit *after* the
        // empty-lines guard, so the button stuck on the wrong icon for lyric-less songs.
        if info.isPlaying != wasPlaying {
            stateLock.lock(); isPlayingSnapshot = info.isPlaying; stateLock.unlock()
            main { self.isPlaying = info.isPlaying }
        }

        guard !lines.isEmpty else { return }

        var idx = -1
        for line in lines {
            if line.time <= info.position { idx = line.id } else { break }
        }
        if idx != current { setActiveIndex(idx) }
    }

    // ── State setters: keep the @Published value (UI) and the snapshot (loops) in sync ──

    private func setLines(_ value: [LRCLine]) {
        stateLock.lock(); linesSnapshot = value; stateLock.unlock()
        main { self.lines = value }
    }

    private func setActiveIndex(_ value: Int) {
        stateLock.lock(); activeIndexSnapshot = value; stateLock.unlock()
        main { self.activeIndex = value }
    }

    private func main(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
