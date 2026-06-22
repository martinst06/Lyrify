import Foundation

struct SpotifyTrackInfo {
    let title: String
    let artist: String
    let album: String
    let durationMs: Int
    let position: Double
    let trackId: String
    let isPlaying: Bool
}

struct SpotifyBridge {
    // Field delimiter: ASCII Unit Separator (U+001F). A literal "|" breaks parsing for any
    // track whose name/artist/album contains a pipe (e.g. Denzel Curry's "BLACK BALLOONS |
    // 13LACK 13ALLOONZ …"). The separator never appears in track metadata.
    private static let sep = "\u{1F}"
    private static let script = """
tell application "Spotify"
    if player state is playing or player state is paused then
        set t to current track
        set d to (character id 31)
        if player state is playing then
            set stStr to "playing"
        else
            set stStr to "paused"
        end if
        return (name of t) & d & (artist of t) & d & (album of t) & d & ((duration of t) as string) & d & ((player position) as string) & d & (id of t as string) & d & stStr
    end if
end tell
"""

    static func getTrackInfo() -> SpotifyTrackInfo? {
        guard let out = run(script), out.contains(sep) else { return nil }
        let parts = out.components(separatedBy: sep)
        guard parts.count >= 6,
              let durationMs = Int(parts[3]),
              let position = Double(parts[4]) else { return nil }
        let trackId = parts[5].components(separatedBy: ":").last ?? ""
        let isPlaying = parts.count > 6 && parts[6] == "playing"
        return SpotifyTrackInfo(
            title: parts[0], artist: parts[1], album: parts[2],
            durationMs: durationMs, position: position,
            trackId: trackId, isPlaying: isPlaying
        )
    }

    // Fire-and-forget commands run on one dedicated serial queue, never on the shared GCD
    // pool. Each osascript call blocks until Spotify answers (and can stall if Spotify is
    // busy); funnelling them here means a slow command can't pile up worker threads and
    // starve the pool — which used to wedge the track loop and make the buttons go dead.
    private static let commandQueue = DispatchQueue(label: "lyrify.spotify.command")

    static func playPause()     { command("tell application \"Spotify\" to playpause") }
    static func nextTrack()     { command("tell application \"Spotify\" to next track") }
    static func previousTrack() { command("tell application \"Spotify\" to previous track") }

    /// Jump playback to a position, in seconds. Spotify's `player position` is a real in seconds.
    static func seek(to seconds: Double) {
        command("tell application \"Spotify\" to set player position to \(max(0, seconds))")
    }

    private static func command(_ source: String) {
        commandQueue.async { run(source) }
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        // Discard stderr rather than wiring an unread Pipe: a stderr pipe whose buffer fills
        // and that nobody drains blocks osascript on write, hanging waitUntilExit forever.
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        // Drain stdout to EOF *before* waiting on exit. Reading after waitUntilExit can
        // deadlock if osascript ever fills the pipe buffer (it blocks writing and never exits).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
