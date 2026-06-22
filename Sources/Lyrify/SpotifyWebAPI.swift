import Foundation

/// Metadata for the song Spotify will play next, used only to warm `LyricsService`'s cache.
struct NextTrack {
    let title: String
    let artist: String
    let album: String
    let durationMs: Int
}

/// Reads the upcoming track from the Spotify Web API. Entirely optional and fail-safe: any
/// error (no auth, no active device, network failure) yields `nil` and the app falls back to
/// fetching lyrics on-demand. All blocking work runs on a dedicated serial queue.
enum SpotifyWebAPI {
    private static let queue = DispatchQueue(label: "lyrify.webapi")

    /// Fetch `queue[0]` off the caller's thread; `completion` runs on the dedicated queue.
    static func nextTrack(_ completion: @escaping (NextTrack?) -> Void) {
        queue.async { completion(fetchNextBlocking()) }
    }

    private static func fetchNextBlocking() -> NextTrack? {
        guard let token = SpotifyAuth.shared.accessToken() else { return nil }
        let url = URL(string: "https://api.spotify.com/v1/me/player/queue")!

        switch get(url, token: token) {
        case .ok(let data):
            return parseNext(data)
        case .unauthorized:
            // Token rejected despite not being expired — force a refresh and retry once.
            SpotifyAuth.shared.invalidate()
            guard let fresh = SpotifyAuth.shared.accessToken(),
                  case .ok(let data) = get(url, token: fresh) else { return nil }
            return parseNext(data)
        case .other:
            return nil
        }
    }

    /// Parse the next playable track from a `/me/player/queue` response. Internal for testing.
    static func parseNext(_ data: Data) -> NextTrack? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = root["queue"] as? [[String: Any]] else { return nil }
        // The first entry is the genuine next item; skip podcast episodes (no artist/album).
        for item in queue { if let t = track(from: item) { return t } }
        return nil
    }

    /// Build a `NextTrack` from one queue item, or nil if it isn't a track. Internal for testing.
    static func track(from item: [String: Any]) -> NextTrack? {
        guard let title = item["name"] as? String,
              let durationMs = item["duration_ms"] as? Int,
              let album = (item["album"] as? [String: Any])?["name"] as? String,
              let artist = (item["artists"] as? [[String: Any]])?.first?["name"] as? String
        else { return nil }
        return NextTrack(title: title, artist: artist, album: album, durationMs: durationMs)
    }

    private enum Resp { case ok(Data); case unauthorized; case other }

    private static func get(_ url: URL, token: String) -> Resp {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var out: Resp = .other
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            switch (resp as? HTTPURLResponse)?.statusCode {
            case 200: if let data = data { out = .ok(data) }
            case 401: out = .unauthorized
            default:  out = .other     // 204 = no active device, etc.
            }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }
}
