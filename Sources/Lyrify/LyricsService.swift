import Foundation

struct LyricsResult {
    var synced: String?
    var plain: String?
}

struct LyricsService {
    // Per-track result cache so skipping back to a song is instant and we don't re-hit
    // LRCLIB. Bounded only by the number of distinct tracks played in a session.
    private static var cache: [String: LyricsResult] = [:]
    private static let cacheLock = NSLock()
    private final class Holder { var value: LyricsResult? }

    // The concurrent search runs here, not on the shared GCD global pool. fetchSync is
    // already serialized by its single caller, so this blocks at most one extra thread at
    // a time — and never one the rest of the app needs.
    private static let searchQueue = DispatchQueue(label: "lyrify.lyrics.search")

    /// `onEarlyPlain` fires as soon as the exact-match lookup returns plain-only lyrics,
    /// before the (slower) synced search finishes — so the UI can show something instead
    /// of "Loading…". The final return value is still the best available result.
    static func fetchSync(title: String, artist: String, album: String, durationMs: Int,
                          onEarlyPlain: ((String) -> Void)? = nil) -> LyricsResult {
        let key = [title, artist, album, String(durationMs)].joined(separator: "\u{1F}")
        cacheLock.lock(); let cached = cache[key]; cacheLock.unlock()
        if let cached = cached { return cached }

        // Start the search concurrently with the exact-match lookup, so a slow LRCLIB
        // costs one round-trip instead of two back-to-back.
        let holder = Holder()
        let group = DispatchGroup()
        group.enter()
        searchQueue.async {
            holder.value = searchMatch(title: title, artist: artist, durationMs: durationMs)
            group.leave()
        }

        var fallbackPlain: String?

        // 1. Exact match (/api/get): the canonical hit. If it carries synced lyrics we
        //    return right away — the in-flight search is harmless and just gets discarded.
        if let r = exactMatch(title: title, artist: artist, album: album, durationMs: durationMs) {
            if r.synced != nil { return store(key, r) }
            if let p = r.plain { fallbackPlain = p; onEarlyPlain?(p) }
        }

        // 2. No exact synced version — fold in the search result (already in flight).
        //    Prefer a synced result; if several exist, the closest duration won.
        group.wait()
        if let r = holder.value {
            if r.synced != nil { return store(key, r) }
            fallbackPlain = fallbackPlain ?? r.plain
        }

        // Cache only positive results; a nil/nil outcome may be a transient network
        // failure we don't want to remember as a permanent miss.
        let result = LyricsResult(synced: nil, plain: fallbackPlain)
        return fallbackPlain != nil ? store(key, result) : result
    }

    @discardableResult
    private static func store(_ key: String, _ result: LyricsResult) -> LyricsResult {
        cacheLock.lock(); cache[key] = result; cacheLock.unlock()
        return result
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
        // LRCLIB can take 7-8s to respond when under load; a tight timeout makes the
        // app drop the connection early and falsely report "No lyrics found."
        var req = URLRequest(url: url, timeoutInterval: 15)
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
