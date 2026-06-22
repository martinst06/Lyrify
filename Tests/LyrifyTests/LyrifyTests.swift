import XCTest
@testable import Lyrify

final class PKCETests: XCTestCase {
    // RFC 7636 Appendix B test vector (verified independently with openssl).
    func testChallengeMatchesRFCVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierIsSpecCompliant() {
        for _ in 0..<100 {
            let v = PKCE.verifier()
            XCTAssert((43...128).contains(v.count), "verifier length \(v.count) out of range")
            let allowed = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            XCTAssertNil(v.unicodeScalars.first { !allowed.contains($0) }, "illegal char in \(v)")
        }
    }

    func testBase64URLHasNoPaddingOrUnsafeChars() {
        let s = PKCE.base64URL(Data([0xfb, 0xff, 0xfe]))   // would yield +/ and = in plain base64
        XCTAssertFalse(s.contains("+") || s.contains("/") || s.contains("="))
    }
}

final class TokenParsingTests: XCTestCase {
    func testParsesAccessAndRefresh() {
        let json = Data(#"{"access_token":"AT","token_type":"Bearer","expires_in":3600,"refresh_token":"RT"}"#.utf8)
        let t = SpotifyAuth.parseTokens(json)
        XCTAssertEqual(t?.accessToken, "AT")
        XCTAssertEqual(t?.refreshToken, "RT")
        XCTAssertEqual(t.map { $0.expiresAt.timeIntervalSinceNow }.map { ($0 - 3600).magnitude < 5 }, true)
    }

    func testRefreshTokenOptional() {
        let json = Data(#"{"access_token":"AT","token_type":"Bearer","expires_in":3600}"#.utf8)
        let t = SpotifyAuth.parseTokens(json)
        XCTAssertEqual(t?.accessToken, "AT")
        XCTAssertEqual(t?.refreshToken, "")
    }

    func testRejectsGarbage() {
        XCTAssertNil(SpotifyAuth.parseTokens(Data("not json".utf8)))
        XCTAssertNil(SpotifyAuth.parseTokens(Data(#"{"error":"invalid_grant"}"#.utf8)))
    }
}

final class QueueParsingTests: XCTestCase {
    private func queueJSON(_ items: String) -> Data {
        Data(#"{"currently_playing":{"name":"now"},"queue":[\#(items)]}"#.utf8)
    }

    func testParsesFirstTrack() {
        let item = #"{"name":"Song","duration_ms":210000,"album":{"name":"Album"},"artists":[{"name":"Artist"},{"name":"Other"}]}"#
        let t = SpotifyWebAPI.parseNext(queueJSON(item))
        XCTAssertEqual(t?.title, "Song")
        XCTAssertEqual(t?.artist, "Artist")   // first artist
        XCTAssertEqual(t?.album, "Album")
        XCTAssertEqual(t?.durationMs, 210000)
    }

    func testSkipsLeadingEpisodeToFindTrack() {
        let episode = #"{"name":"Podcast Ep","duration_ms":1000,"type":"episode"}"#
        let track = #"{"name":"Song","duration_ms":200000,"album":{"name":"Album"},"artists":[{"name":"Artist"}]}"#
        let t = SpotifyWebAPI.parseNext(queueJSON("\(episode),\(track)"))
        XCTAssertEqual(t?.title, "Song")
    }

    func testEmptyQueueIsNil() {
        XCTAssertNil(SpotifyWebAPI.parseNext(queueJSON("")))
    }
}

final class HTTPRequestParsingTests: XCTestCase {
    func testExtractsCodeAndState() {
        let req = "GET /callback?code=AQ-abc_123&state=xyz HTTP/1.1\r\nHost: 127.0.0.1:8888\r\n\r\n"
        XCTAssertEqual(SpotifyAuth.queryValue(req, "code"), "AQ-abc_123")
        XCTAssertEqual(SpotifyAuth.queryValue(req, "state"), "xyz")
    }

    func testMissingParamIsNil() {
        let req = "GET /callback?error=access_denied HTTP/1.1\r\n\r\n"
        XCTAssertNil(SpotifyAuth.queryValue(req, "code"))
    }
}
