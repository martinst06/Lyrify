import Foundation
import CryptoKit
import AppKit
import Network

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// PKCE helpers (RFC 7636). Pure + isolated so they can be unit-tested without any network.
enum PKCE {
    /// A high-entropy `code_verifier`: 64 random bytes, base64url-encoded (~86 chars, within
    /// the spec's 43–128 range, using only the unreserved subset `A-Za-z0-9-_`).
    static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    /// `code_challenge` = base64url(SHA256(verifier)), the `S256` method.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Authorization Code + PKCE for the Spotify Web API. First run opens the browser once to log
/// in; after that, tokens refresh silently. Everything is best-effort — any failure returns
/// `nil` from `accessToken()` and the caller simply skips that cycle.
final class SpotifyAuth {
    static let shared = SpotifyAuth()

    private let clientId: String?
    private let redirectURI = "http://127.0.0.1:8888/callback"
    private let port: UInt16 = 8888
    private let scope = "user-read-playback-state"

    private let lock = NSLock()
    private var tokens: SpotifyTokens?
    private var authAttempted = false   // run the interactive (browser) flow at most once/session

    private var tokensPath: URL { SpotifyConfig.supportDir.appendingPathComponent("tokens.json") }

    init() {
        clientId = SpotifyConfig.clientId
        tokens = loadTokens()
    }

    /// A valid access token, refreshing or running the one-time login as needed.
    /// `nil` ⇒ no client ID configured, or auth unavailable this session.
    func accessToken() -> String? {
        guard let clientId = clientId else { return nil }

        lock.lock(); let current = tokens; lock.unlock()

        if let t = current, t.expiresAt > Date().addingTimeInterval(60) { return t.accessToken }

        if let t = current {
            if let refreshed = refresh(token: t.refreshToken, clientId: clientId) {
                lock.lock(); tokens = refreshed; lock.unlock(); saveTokens(refreshed)
                return refreshed.accessToken
            }
            // Refresh failed (token likely revoked) — drop it so we can re-auth.
            lock.lock(); tokens = nil; lock.unlock()
        }

        lock.lock(); let attempted = authAttempted; authAttempted = true; lock.unlock()
        if !attempted, let new = interactiveAuth(clientId: clientId) {
            lock.lock(); tokens = new; lock.unlock(); saveTokens(new)
            return new.accessToken
        }
        return nil
    }

    /// Mark the current access token stale so the next `accessToken()` forces a refresh —
    /// used when the API answers 401 despite a not-yet-expired token.
    func invalidate() {
        lock.lock(); if var t = tokens { t.expiresAt = .distantPast; tokens = t }; lock.unlock()
    }

    // ── Interactive PKCE flow ────────────────────────────────────────────────

    private func interactiveAuth(clientId: String) -> SpotifyTokens? {
        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))

        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        guard let authURL = c.url,
              let code = waitForCode(expectedState: state, opening: authURL) else { return nil }
        return exchange(code: code, verifier: verifier, clientId: clientId)
    }

    /// Start a one-shot loopback listener, open the browser, and block (≤120s) until Spotify
    /// redirects back with `?code=`. Returns nil on timeout, mismatched state, or bind failure.
    private func waitForCode(expectedState: String, opening authURL: URL) -> String? {
        guard let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { return nil }

        var code: String?
        let sem = DispatchSemaphore(value: 0)

        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                if let data = data, let request = String(data: data, encoding: .utf8),
                   let c = Self.queryValue(request, "code"),
                   Self.queryValue(request, "state") == expectedState {
                    code = c
                }
                let body = Data("Lyrify is connected — you can close this tab.".utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body,
                          completion: .contentProcessed { _ in conn.cancel(); sem.signal() })
            }
        }
        listener.start(queue: .global())
        NSWorkspace.shared.open(authURL)
        let timedOut = sem.wait(timeout: .now() + 120) == .timedOut
        listener.cancel()
        return timedOut ? nil : code
    }

    /// Extract a query parameter from a raw HTTP request's start line
    /// (`GET /callback?code=…&state=… HTTP/1.1`). Internal for unit testing.
    static func queryValue(_ request: String, _ key: String) -> String? {
        guard let startLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let fields = startLine.split(separator: " ")
        guard fields.count >= 2,
              let comps = URLComponents(string: "http://127.0.0.1" + fields[1]) else { return nil }
        return comps.queryItems?.first { $0.name == key }?.value
    }

    // ── Token endpoint ───────────────────────────────────────────────────────

    private func exchange(code: String, verifier: String, clientId: String) -> SpotifyTokens? {
        tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
    }

    private func refresh(token: String, clientId: String) -> SpotifyTokens? {
        guard let new = tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": token,
            "client_id": clientId,
        ]) else { return nil }
        // Spotify usually omits refresh_token on refresh — keep the existing one.
        return new.refreshToken.isEmpty
            ? SpotifyTokens(accessToken: new.accessToken, refreshToken: token, expiresAt: new.expiresAt)
            : new
    }

    private func tokenRequest(_ form: [String: String]) -> SpotifyTokens? {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\(Self.formEscape($0.value))" }.joined(separator: "&").utf8)

        var data: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { data = d }
            sem.signal()
        }.resume()
        sem.wait()
        return data.flatMap { Self.parseTokens($0) }
    }

    /// Parse Spotify's token response. Internal for unit testing.
    static func parseTokens(_ data: Data) -> SpotifyTokens? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = dict["access_token"] as? String,
              let expiresIn = dict["expires_in"] as? Double else { return nil }
        let refresh = dict["refresh_token"] as? String ?? ""
        return SpotifyTokens(accessToken: access, refreshToken: refresh,
                             expiresAt: Date().addingTimeInterval(expiresIn))
    }

    private static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // ── Token persistence (0600 file in Application Support) ──────────────────

    private func loadTokens() -> SpotifyTokens? {
        (try? Data(contentsOf: tokensPath)).flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
    }

    private func saveTokens(_ t: SpotifyTokens) {
        try? FileManager.default.createDirectory(at: SpotifyConfig.supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(t) else { return }
        try? data.write(to: tokensPath, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensPath.path)
    }
}
