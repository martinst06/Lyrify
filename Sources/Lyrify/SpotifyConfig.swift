import Foundation

/// Local, un-committed config for the optional Spotify Web API features (next-track lyric
/// preload). Lives in Application Support so it never lands in the repo.
///
///     ~/Library/Application Support/Lyrify/config.json   { "clientId": "…" }
///
/// No `clientId` ⇒ the whole Web API layer stays disabled and the app behaves exactly as it
/// did before (lyrics still fetched on-demand via AppleScript + LRCLIB).
enum SpotifyConfig {
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrify", isDirectory: true)
    }

    static var clientId: String? {
        let url = supportDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = dict["clientId"] as? String, !id.isEmpty else { return nil }
        return id
    }
}
