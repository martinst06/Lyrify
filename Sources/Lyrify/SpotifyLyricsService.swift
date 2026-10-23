import Foundation
import CryptoKit

/// Why Spotify's lyrics are currently unavailable; drives the warning icon.
enum SpotifyLyricsWarning: Equatable {
    case cookieRejected   // sp_dc expired or signed out — needs a new cookie in config.json
    case loginChanged     // Spotify rotated its web-player TOTP secret
}

/// The lyrics the Spotify app itself shows, from the web player's private `color-lyrics`
/// endpoint. Unofficial: logs in with the user's `sp_dc` cookie plus a TOTP whose secret the
/// community republishes each time Spotify rotates it. Off unless `spDc` is configured; any
/// failure returns nil so `LyricsService` falls through to LRCLIB.
enum SpotifyLyricsService {
    enum TokenResponse: Equatable {
        case token(String, expiresAt: Date)
        case cookieRejected
        case loginRejected
    }

    /// Why minting is paused. Outlives its blocking window: it's cleared only by a successful
    /// login, so the warning stays up until Spotify lyrics actually work again.
    enum Block {
        case cookieRejected(cookie: String)
        case loginChanged(since: Date)

        func blocks(cookie: String, now: Date) -> Bool {
            switch self {
            case .cookieRejected(let rejected): return cookie == rejected
            case .loginChanged(let since):      return now.timeIntervalSince(since) < 600
            }
        }

        var warning: SpotifyLyricsWarning {
            switch self {
            case .cookieRejected: return .cookieRejected
            case .loginChanged:   return .loginChanged
            }
        }
    }

    private static let secretsURL = URL(string: "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    // Minting happens while holding the lock, so the lyric fetch and the next-track preload
    // never log in twice at once.
    private static let lock = NSLock()
    private static var secret: (key: Data, version: String)?
    private static var token: (value: String, expiresAt: Date, cookie: String)?
    private static var block: Block?

    static var warning: SpotifyLyricsWarning? {
        lock.lock(); defer { lock.unlock() }
        return block?.warning
    }

    /// Blocking — call from `fetchQueue` or the Web API queue, never main or the GCD pool.
    static func fetch(trackId: String) -> LyricsResult? {
        guard isTrackId(trackId) else { return nil }
        guard let cookie = SpotifyConfig.spDc else {
            lock.lock(); block = nil; token = nil; lock.unlock()
            return nil
        }
        guard let first = accessToken(cookie: cookie) else { return nil }
        var response = lyrics(trackId: trackId, token: first)
        if response?.status == 401 {
            lock.lock(); token = nil; lock.unlock()
            guard let fresh = accessToken(cookie: cookie) else { return nil }
            response = lyrics(trackId: trackId, token: fresh)
        }
        guard let r = response, r.status == 200 else { return nil }
        return parseLyrics(r.data)
    }

    private static func accessToken(cookie: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let t = token, t.cookie == cookie, t.expiresAt > now.addingTimeInterval(60) { return t.value }
        if let b = block, b.blocks(cookie: cookie, now: now) { return nil }

        var outcome = mint(cookie: cookie)
        if outcome == .loginRejected {
            secret = nil   // likely rotated — re-download once before giving up
            outcome = mint(cookie: cookie)
        }
        switch outcome {
        case .token(let value, let expiresAt)?:
            token = (value, expiresAt, cookie)
            block = nil
            return value
        case .cookieRejected?:
            block = .cookieRejected(cookie: cookie)
            NSLog("Lyrify: Spotify rejected the sp_dc cookie; using LRCLIB until it's replaced")
        case .loginRejected?:
            block = .loginChanged(since: now)
            NSLog("Lyrify: Spotify web-player login failed (TOTP secret likely rotated); using LRCLIB")
        case nil:
            break   // no response — just retry on the next track
        }
        return nil
    }

    /// One login attempt; nil ⇒ no response at all (offline), which blocks nothing.
    private static func mint(cookie: String) -> TokenResponse? {
        if secret == nil {
            guard let r = get(secretsURL) else { return nil }
            guard r.status == 200,
                  let dict = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
                  let version = dict.keys.max(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }),
                  let bytes = dict[version] as? [Int] else { return .loginRejected }
            secret = (Data(decodeSecret(bytes).utf8), version)
        }
        guard let s = secret else { return nil }

        let serverTime = get(URL(string: "https://open.spotify.com/api/server-time")!)
            .flatMap { try? JSONSerialization.jsonObject(with: $0.data) as? [String: Any] }
            .flatMap { ($0["serverTime"] as? NSNumber)?.intValue }
            ?? Int(Date().timeIntervalSince1970)

        var c = URLComponents(string: "https://open.spotify.com/api/token")!
        c.queryItems = [
            .init(name: "reason",      value: "transport"),
            .init(name: "productType", value: "web-player"),
            .init(name: "totp",        value: totp(secret: s.key, time: serverTime)),
            .init(name: "totpVer",     value: s.version),
            .init(name: "ts",          value: String(Int(Date().timeIntervalSince1970))),
        ]
        guard let r = get(c.url!, headers: ["Cookie": "sp_dc=\(cookie)"]) else { return nil }
        return parseToken(status: r.status, data: r.data)
    }

    private static func lyrics(trackId: String, token: String) -> (status: Int, data: Data)? {
        let url = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackId)?format=json&market=from_token")!
        return get(url, headers: ["Authorization": "Bearer \(token)", "App-Platform": "WebPlayer"])
    }

    /// nil ⇒ no HTTP response; otherwise the status and body, whatever the status.
    private static func get(_ url: URL, headers: [String: String] = [:]) -> (status: Int, data: Data)? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpShouldHandleCookies = false   // send our sp_dc header as-is; keep Spotify's cookies out of the shared jar
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        var out: (status: Int, data: Data)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse { out = (http.statusCode, data ?? Data()) }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    // ── Pure helpers (unit-tested) ──────────────────────────────────────────

    /// Spotify track IDs are 22 base62 chars; anything else (local files, episodes) is skipped.
    static func isTrackId(_ id: String) -> Bool {
        id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// The published secret is obfuscated byte-by-byte; the HMAC key is the decimal digits of
    /// each de-obfuscated byte, concatenated.
    static func decodeSecret(_ bytes: [Int]) -> String {
        bytes.enumerated().map { String($1 ^ (($0 % 33) + 9)) }.joined()
    }

    /// RFC 6238 TOTP: HMAC-SHA1, 30 s step, 6 digits.
    static func totp(secret: Data, time: Int) -> String {
        var counter = UInt64(time / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let code = mac[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF
        return String(format: "%06u", code % 1_000_000)
    }

    /// An invalid cookie gets 401 (an absent one gets an anonymous token); a wrong TOTP gets 400.
    static func parseToken(status: Int, data: Data) -> TokenResponse {
        if status == 401 { return .cookieRejected }
        guard status == 200,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .loginRejected }
        if dict["isAnonymous"] as? Bool == true { return .cookieRejected }
        guard let value = dict["accessToken"] as? String, !value.isEmpty,
              let expiresMs = (dict["accessTokenExpirationTimestampMs"] as? NSNumber)?.doubleValue
        else { return .loginRejected }
        return .token(value, expiresAt: Date(timeIntervalSince1970: expiresMs / 1000))
    }

    /// Timed lines become an LRC string so the existing `LRCParser`/highlight/seek path applies
    /// unchanged; anything else is treated as plain text.
    static func parseLyrics(_ data: Data) -> LyricsResult? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = root["lyrics"] as? [String: Any],
              let lines = lyrics["lines"] as? [[String: Any]], !lines.isEmpty else { return nil }

        let words = lines.map { $0["words"] as? String ?? "" }
        let plain = words.joined(separator: "\n")
        guard ["LINE_SYNCED", "SYLLABLE_SYNCED"].contains(lyrics["syncType"] as? String ?? "") else {
            return LyricsResult(synced: nil, plain: plain)
        }

        let lrc = zip(lines, words).map { line, text -> String in
            let ms = Int(line["startTimeMs"] as? String ?? "") ?? 0
            return String(format: "[%02d:%06.3f]", ms / 60_000, Double(ms % 60_000) / 1000) + text
        }
        return LyricsResult(synced: lrc.joined(separator: "\n"), plain: plain)
    }
}
