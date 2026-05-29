import Foundation

struct LyricsResult {
    var synced: String?
    var plain: String?
}

struct LyricsService {
    static func fetchSync(title: String, artist: String, album: String, durationMs: Int) -> LyricsResult {
        if let r = exactMatch(title: title, artist: artist, album: album, durationMs: durationMs) { return r }
        if let r = searchMatch(title: title, artist: artist) { return r }
        return LyricsResult()
    }

    private static func exactMatch(title: String, artist: String, album: String, durationMs: Int) -> LyricsResult? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            .init(name: "track_name",  value: title),
            .init(name: "artist_name", value: artist),
            .init(name: "album_name",  value: album),
            .init(name: "duration",    value: String(durationMs / 1000)),
        ]
        return c.url.flatMap { get($0) }
    }

    private static func searchMatch(title: String, artist: String) -> LyricsResult? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [
            .init(name: "track_name",  value: title),
            .init(name: "artist_name", value: artist),
        ]
        guard let url = c.url, let data = syncFetch(url: url) else { return nil }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for item in arr {
            let s = item["syncedLyrics"] as? String
            let p = item["plainLyrics"]  as? String
            if s != nil || p != nil { return LyricsResult(synced: s, plain: p) }
        }
        return nil
    }

    private static func get(_ url: URL) -> LyricsResult? {
        guard let data = syncFetch(url: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let s = dict["syncedLyrics"] as? String
        let p = dict["plainLyrics"]  as? String
        guard s != nil || p != nil else { return nil }
        return LyricsResult(synced: s, plain: p)
    }

    private static func syncFetch(url: URL) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Lyrify/1.0", forHTTPHeaderField: "User-Agent")
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}
