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
    private static let script = """
tell application "Spotify"
    if player state is playing or player state is paused then
        set t to current track
        if player state is playing then
            set stStr to "playing"
        else
            set stStr to "paused"
        end if
        return (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & ((duration of t) as string) & "|" & ((player position) as string) & "|" & (id of t as string) & "|" & stStr
    end if
end tell
"""

    static func getTrackInfo() -> SpotifyTrackInfo? {
        guard let out = run(script), out.contains("|") else { return nil }
        let parts = out.components(separatedBy: "|")
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

    static func playPause()     { run("tell application \"Spotify\" to playpause") }
    static func nextTrack()     { run("tell application \"Spotify\" to next track") }
    static func previousTrack() { run("tell application \"Spotify\" to previous track") }

    /// Jump playback to a position, in seconds. Spotify's `player position` is a real in seconds.
    static func seek(to seconds: Double) {
        run("tell application \"Spotify\" to set player position to \(max(0, seconds))")
    }

    @discardableResult
    private static func run(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
