import Foundation

class LyricsViewModel: ObservableObject {
    @Published var lines: [LRCLine] = []
    @Published var activeIndex: Int = -1
    @Published var statusMessage: String = "Waiting for Spotify…"
    @Published var trackTitle: String = ""
    @Published var trackArtist: String = ""
    @Published var isPlaying: Bool = false

    private var currentKey = ""
    init() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.trackLoop() }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in self?.positionLoop() }
    }

    // ── Track change loop ────────────────────────────────────────────────────

    private func trackLoop() {
        while true {
            checkTrack()
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    private func checkTrack() {
        guard let info = SpotifyBridge.getTrackInfo() else {
            if !currentKey.isEmpty {
                currentKey = ""
                main { self.lines = []; self.statusMessage = "Waiting for Spotify…" }
            }
            return
        }

        let key = "\(info.title)|\(info.artist)"
        guard key != currentKey else { return }
        currentKey = key

        main {
            self.lines = []
            self.activeIndex = -1
            self.trackTitle = info.title
            self.trackArtist = info.artist
            self.statusMessage = "Loading…"
        }

        let result = LyricsService.fetchSync(
            title: info.title, artist: info.artist,
            album: info.album, durationMs: info.durationMs
        )

        if let synced = result.synced {
            let parsed = LRCParser.parse(synced)
            if !parsed.isEmpty { main { self.lines = parsed }; return }
        }
        main { self.statusMessage = result.plain ?? "No lyrics found." }
    }

    // ── Seek ───────────────────────────────────────────────────────────────

    /// Jump Spotify to a tapped lyric line. Updates the highlight immediately
    /// for instant feedback; the position loop reconciles once Spotify catches up.
    func seek(to line: LRCLine) {
        activeIndex = line.id
        DispatchQueue.global().async { SpotifyBridge.seek(to: line.time) }
    }

    // ── Position loop ────────────────────────────────────────────────────────

    private func positionLoop() {
        while true {
            updatePosition()
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    private func updatePosition() {
        let (lines, current) = DispatchQueue.main.sync { (self.lines, self.activeIndex) }
        guard !lines.isEmpty, let info = SpotifyBridge.getTrackInfo() else { return }

        var idx = -1
        for line in lines {
            if line.time <= info.position { idx = line.id } else { break }
        }
        if idx != current { main { self.activeIndex = idx } }
        if info.isPlaying != self.isPlaying { main { self.isPlaying = info.isPlaying } }
    }

    private func main(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
