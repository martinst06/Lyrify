import Foundation

/// Last-resort lyrics source for tracks LRCLIB has nothing for. Genius has no
/// lyrics-in-API — its API/search returns only metadata and a page URL — so the words
/// are scraped straight from the song page's HTML. That means **plain text only**,
/// never synced (no auto-scroll, no click-to-seek); it renders through the same
/// plain-text path as an LRCLIB plain fallback.
///
/// Always on. An optional `geniusToken` in config.json switches song lookup to the
/// official `api.genius.com/search` endpoint for sharper matching; without it we use
/// Genius's public web search. Either way the lyrics themselves come from the scrape.
///
/// Called only at the tail of `LyricsService.fetchSync` (after LRCLIB comes up empty),
/// so it runs on the same dedicated serial queue and blocks nothing the app needs —
/// never the shared GCD global pool. See the threading notes in CLAUDE.md.
enum GeniusService {

    /// Returns scraped plain lyrics for the best-matching Genius song, or nil when
    /// nothing matches confidently / the page can't be scraped.
    static func fetchPlain(title: String, artist: String) -> String? {
        guard let hit = findSong(title: title, artist: artist) else { return nil }
        // Genius search happily returns *a* song even for a bad query. Only trust a hit
        // whose title/artist actually resemble the track — otherwise we'd paste some
        // unrelated song's lyrics over the current one.
        guard matchScore(candidateTitle: hit.title, candidateArtist: hit.artist,
                         wantTitle: title, wantArtist: artist) >= 0.5 else { return nil }
        guard let html = fetchText(hit.url) else { return nil }
        let lyrics = scrapeLyrics(from: html)
        return (lyrics?.isEmpty ?? true) ? nil : lyrics
    }

    // MARK: - Song lookup

    private struct Hit { let title: String; let artist: String; let url: URL }

    private static func findSong(title: String, artist: String) -> Hit? {
        let query = "\(title) \(artist)"
        let results: [[String: Any]]
        if let token = SpotifyConfig.geniusToken {
            results = officialSearch(query: query, token: token)
        } else {
            results = publicSearch(query: query)
        }

        // Pick the result whose title+artist best matches the track.
        var best: (hit: Hit, score: Double)?
        for r in results {
            guard let hit = hit(from: r) else { continue }
            let score = matchScore(candidateTitle: hit.title, candidateArtist: hit.artist,
                                   wantTitle: title, wantArtist: artist)
            if best == nil || score > best!.score { best = (hit, score) }
        }
        return best?.hit
    }

    /// Official API: `{ "response": { "hits": [ { "result": {…} } ] } }` (Bearer auth).
    private static func officialSearch(query: String, token: String) -> [[String: Any]] {
        guard var c = URLComponents(string: "https://api.genius.com/search") else { return [] }
        c.queryItems = [.init(name: "q", value: query)]
        guard let url = c.url else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = fetchData(req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any] else { return [] }
        return collectResults(from: response)
    }

    /// Public web search (no key). `search/multi` groups hits into `sections`; the plain
    /// `search` endpoint returns a flat `hits` array — `collectResults` handles both.
    private static func publicSearch(query: String) -> [[String: Any]] {
        guard var c = URLComponents(string: "https://genius.com/api/search/multi") else { return [] }
        c.queryItems = [.init(name: "q", value: query)]
        guard let url = c.url, let data = fetchData(URLRequest(url: url, timeoutInterval: 10)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any] else { return [] }
        return collectResults(from: response)
    }

    /// Pulls `result` dicts out of a Genius `response`, whether they live in a top-level
    /// `hits` array (official / plain search) or under `sections[].hits` (search/multi).
    private static func collectResults(from response: [String: Any]) -> [[String: Any]] {
        var results: [[String: Any]] = []
        if let hits = response["hits"] as? [[String: Any]] {
            results += hits.compactMap { $0["result"] as? [String: Any] }
        }
        if let sections = response["sections"] as? [[String: Any]] {
            for section in sections {
                if let hits = section["hits"] as? [[String: Any]] {
                    results += hits.compactMap { $0["result"] as? [String: Any] }
                }
            }
        }
        return results
    }

    private static func hit(from result: [String: Any]) -> Hit? {
        guard let title = result["title"] as? String,
              let urlString = result["url"] as? String, let url = URL(string: urlString) else { return nil }
        let artist = (result["primary_artist"] as? [String: Any])?["name"] as? String ?? ""
        return Hit(title: title, artist: artist, url: url)
    }

    // MARK: - Matching

    /// 0…1 confidence that a Genius hit is the track we're after. Weighs how many of the
    /// wanted title words appear in the candidate title (0.7) plus whether any artist word
    /// overlaps (0.3). Both sides are normalized (lowercased, diacritics/punctuation
    /// stripped) so "Coby & Senidah" matches "Coby, Senidah".
    static func matchScore(candidateTitle: String, candidateArtist: String,
                           wantTitle: String, wantArtist: String) -> Double {
        let want = tokens(wantTitle)
        guard !want.isEmpty else { return 0 }
        let cand = tokens(candidateTitle)
        let titleScore = Double(want.intersection(cand).count) / Double(want.count)

        let wantArt = tokens(wantArtist)
        let candArt = tokens(candidateArtist)
        let artistScore = wantArt.isEmpty || !wantArt.isDisjoint(with: candArt) ? 1.0 : 0.0

        return titleScore * 0.7 + artistScore * 0.3
    }

    /// Normalized word set: fold diacritics, lowercase, drop anything non-alphanumeric.
    private static func tokens(_ s: String) -> Set<String> {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return Set(String(cleaned).split(separator: " ").map(String.init))
    }

    // MARK: - Scraping

    /// Extracts and cleans the lyrics from a Genius song page. Genius wraps the words in
    /// one or more `<div data-lyrics-container="true">` blocks with `<br>` line breaks and
    /// inline `<a>`/`<span>` annotation tags. Returns clean newline-separated text.
    static func scrapeLyrics(from html: String) -> String? {
        let blocks = lyricBlocks(html)
        guard !blocks.isEmpty else { return nil }
        let text = blocks.map(cleanBlock).joined(separator: "\n")
        // Collapse runs of blank lines the tag-stripping can leave behind, then trim.
        let collapsed = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n",
                                                  options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Inner HTML of every `data-lyrics-container` div, matched with a depth counter so
    /// nested `<div>`s (headers, annotations) don't cut a block short — a non-greedy
    /// regex would stop at the first `</div>`.
    private static func lyricBlocks(_ html: String) -> [String] {
        var blocks: [String] = []
        var searchStart = html.startIndex
        while let marker = html.range(of: "data-lyrics-container",
                                      range: searchStart..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: marker.upperBound..<html.endIndex) else { break }
            let contentStart = tagEnd.upperBound
            let close = matchingDivClose(in: html, contentStart: contentStart)
            blocks.append(String(html[contentStart..<close.innerEnd]))
            searchStart = close.after
        }
        return blocks
    }

    /// Given the index just past a `<div …>` opening tag, finds its matching `</div>` with
    /// a depth counter and returns where the inner content ends plus where the whole
    /// element ends (just past the closing `>`).
    private static func matchingDivClose(in html: String,
                                         contentStart: String.Index) -> (innerEnd: String.Index, after: String.Index) {
        var depth = 1
        var cursor = contentStart
        while depth > 0, let tag = nextDivTag(in: html, from: cursor) {
            cursor = tag.range.upperBound
            if tag.isOpen {
                depth += 1
            } else {
                depth -= 1
                if depth == 0 {
                    let after = html.range(of: ">", range: cursor..<html.endIndex)?.upperBound ?? html.endIndex
                    return (tag.range.lowerBound, after)
                }
            }
        }
        return (html.endIndex, html.endIndex)
    }

    /// Next `<div…` (open) or `</div` (close) at or after `from`, whichever comes first.
    private static func nextDivTag(in html: String,
                                   from: String.Index) -> (range: Range<String.Index>, isOpen: Bool)? {
        let open = html.range(of: "<div", options: .caseInsensitive, range: from..<html.endIndex)
        let close = html.range(of: "</div", options: .caseInsensitive, range: from..<html.endIndex)
        switch (open, close) {
        case let (o?, c?): return o.lowerBound < c.lowerBound ? (o, true) : (c, false)
        case let (o?, nil): return (o, true)
        case let (nil, c?): return (c, false)
        default: return nil
        }
    }

    /// Removes `<div data-exclude-from-selection="true">…</div>` subtrees — Genius marks
    /// all non-lyric chrome (the "N Contributors / … Lyrics" header, inline buttons,
    /// "You might also like") with this attribute, and it can be nested *inside* a lyrics
    /// container.
    private static func stripExcluded(_ block: String) -> String {
        var s = block
        var from = s.startIndex
        while let attr = s.range(of: "data-exclude-from-selection", range: from..<s.endIndex) {
            // Back up to the `<div` that opens this tag, and confirm the attribute really
            // lives in that opening tag (no `>` between the `<div` and the attribute).
            guard let open = s.range(of: "<div", options: .backwards, range: s.startIndex..<attr.lowerBound),
                  s.range(of: ">", range: open.upperBound..<attr.lowerBound) == nil,
                  let tagEnd = s.range(of: ">", range: attr.upperBound..<s.endIndex) else {
                from = attr.upperBound
                continue
            }
            let after = matchingDivClose(in: s, contentStart: tagEnd.upperBound).after
            s.removeSubrange(open.lowerBound..<after)
            from = open.lowerBound
        }
        return s
    }

    private static func cleanBlock(_ block: String) -> String {
        var s = stripExcluded(block)
        for br in ["<br/>", "<br />", "<br>"] {
            s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        // Strip every remaining tag, then decode entities last so a decoded "&lt;" can't
        // reintroduce angle brackets that we'd wrongly treat as a tag.
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(s)
    }

    /// Decodes the HTML entities Genius emits (named + numeric decimal/hex).
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, char) in named { out = out.replacingOccurrences(of: entity, with: char) }
        guard let re = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return out }
        let matches = re.matches(in: out, range: NSRange(out.startIndex..., in: out))
        for m in matches.reversed() {
            guard let full = Range(m.range, in: out), let digits = Range(m.range(at: 1), in: out) else { continue }
            let raw = out[digits]
            let value = raw.hasPrefix("x") || raw.hasPrefix("X")
                ? UInt32(raw.dropFirst(), radix: 16)
                : UInt32(raw, radix: 10)
            if let value = value, let scalar = Unicode.Scalar(value) {
                out.replaceSubrange(full, with: String(scalar))
            }
        }
        return out
    }

    // MARK: - Networking (blocking; runs on fetchSync's serial queue)

    private static func fetchData(_ request: URLRequest) -> Data? {
        var req = request
        // A browser-ish User-Agent — Genius returns 403 for obviously-scripted clients.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                     "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private static func fetchText(_ url: URL) -> String? {
        guard let data = fetchData(URLRequest(url: url, timeoutInterval: 12)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
