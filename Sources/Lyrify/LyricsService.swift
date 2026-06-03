import Foundation

struct LyricsResult {
    var synced: String?
    var plain: String?
}

struct LyricsService {
    static func fetchSync(title: String, artist: String, album: String, durationMs: Int) -> LyricsResult {
        var fallbackPlain: String?

        // 1. Exact match (/api/get). Use it only if it actually carries synced lyrics;
        //    otherwise hold onto its plain text and keep looking for a synced version.
        if let r = exactMatch(title: title, artist: artist, album: album, durationMs: durationMs) {
            if r.synced != nil { return r }
            fallbackPlain = r.plain
        }

        // 2. Search (/api/search). Prefer a synced result; if several exist, the closest
        //    duration wins — multiple cuts of a song often coexist under variant titles.
        if let r = searchMatch(title: title, artist: artist, durationMs: durationMs) {
            if r.synced != nil { return r }
            fallbackPlain = fallbackPlain ?? r.plain
        }

        return LyricsResult(synced: nil, plain: fallbackPlain)
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

    private static func searchMatch(title: String, artist: String, durationMs: Int) -> LyricsResult? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [
            .init(name: "track_name",  value: title),
            .init(name: "artist_name", value: artist),
        ]
        guard let url = c.url, let data = syncFetch(url: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        let target = Double(durationMs) / 1000.0
        var best: (synced: String, plain: String?, delta: Double)?
        var firstPlain: String?

        for item in arr {
            let plain = nonEmpty(item["plainLyrics"])
            if let synced = nonEmpty(item["syncedLyrics"]) {
                let delta = abs((item["duration"] as? Double ?? target) - target)
                if best == nil || delta < best!.delta { best = (synced, plain, delta) }
            }
            if firstPlain == nil { firstPlain = plain }
        }

        if let best = best { return LyricsResult(synced: best.synced, plain: best.plain) }
        return firstPlain.map { LyricsResult(synced: nil, plain: $0) }
    }

    private static func get(_ url: URL) -> LyricsResult? {
        guard let data = syncFetch(url: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let s = nonEmpty(dict["syncedLyrics"])
        let p = nonEmpty(dict["plainLyrics"])
        guard s != nil || p != nil else { return nil }
        return LyricsResult(synced: s, plain: p)
    }

    /// LRCLIB returns `null` or `""` for absent lyrics — collapse both to nil.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
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
