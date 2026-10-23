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

    func testParsesTrackIdForSpotifyLyricsPreload() {
        let item = #"{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Song","duration_ms":210000,"album":{"name":"Album"},"artists":[{"name":"Artist"}]}"#
        XCTAssertEqual(SpotifyWebAPI.parseNext(queueJSON(item))?.trackId, "4uLU6hMCjMI75M1A2tKUQC")
    }
}

final class TrackIdentityTests: XCTestCase {
    private func track(id: String, position: Double = 0) -> SpotifyTrackInfo {
        SpotifyTrackInfo(title: "Song", artist: "Artist", album: "Album",
                         durationMs: 180_000, position: position, trackId: id, isPlaying: true)
    }

    func testSameTitleAndArtistWithDifferentSpotifyIDsAreDifferentTracks() {
        XCTAssertNotEqual(track(id: "first").identity, track(id: "second").identity)
    }

    func testPlaybackPositionDoesNotChangeTrackIdentity() {
        XCTAssertEqual(track(id: "first", position: 5).identity,
                       track(id: "first", position: 100).identity)
    }
}

final class PlainScrollTests: XCTestCase {
    // ── progress(positionSec:durationMs:) — playback fraction, clamped 0...1 ──

    func testProgressMidpoint() {
        XCTAssertEqual(PlainScroll.progress(positionSec: 100, durationMs: 200_000), 0.5, accuracy: 1e-9)
    }

    func testProgressAtStartIsZero() {
        XCTAssertEqual(PlainScroll.progress(positionSec: 0, durationMs: 200_000), 0)
    }

    func testProgressClampsAboveOne() {
        // Position past the reported duration (Spotify occasionally over-reports) stays at 1.
        XCTAssertEqual(PlainScroll.progress(positionSec: 500, durationMs: 200_000), 1)
    }

    func testProgressClampsBelowZero() {
        XCTAssertEqual(PlainScroll.progress(positionSec: -5, durationMs: 200_000), 0)
    }

    func testProgressZeroDurationIsZero() {
        // Guards divide-by-zero for a not-yet-loaded / malformed duration.
        XCTAssertEqual(PlainScroll.progress(positionSec: 100, durationMs: 0), 0)
        XCTAssertEqual(PlainScroll.progress(positionSec: 100, durationMs: -1), 0)
    }

    // ── targetLine(progress:lineCount:) — line index to scroll to ──

    func testTargetLineAtStart() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 0, lineCount: 10), 0)
    }

    func testTargetLineAtEnd() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 1, lineCount: 10), 9)
    }

    func testTargetLineMidpointRounds() {
        // 0.5 * (11 - 1) = 5.0
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.5, lineCount: 11), 5)
        // 0.5 * (10 - 1) = 4.5 → rounds to 5 (round-half-up)
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.5, lineCount: 10), 5)
    }

    func testFasterSpeedMovesFurtherThroughPlainLyrics() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.5, lineCount: 11, speed: 1.2), 6)
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.9, lineCount: 11, speed: 1.25), 9)
        XCTAssertEqual(PlainScroll.targetLine(progress: 1, lineCount: 11, speed: 1.25), 10)
    }

    func testSlowerSpeedLeavesMorePlainLyricsForLater() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.5, lineCount: 11, speed: 0.8), 4)
        XCTAssertEqual(PlainScroll.targetLine(progress: 1, lineCount: 11, speed: 0.75), 10)
    }

    func testTargetLineClampsWithinBounds() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 1.5, lineCount: 10), 9)
        XCTAssertEqual(PlainScroll.targetLine(progress: -0.5, lineCount: 10), 0)
    }

    func testTargetLineEmptyOrSingle() {
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.7, lineCount: 0), 0)
        XCTAssertEqual(PlainScroll.targetLine(progress: 0.7, lineCount: 1), 0)
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

final class GeniusMatchTests: XCTestCase {
    private func matches(_ candTitle: String, _ candArtist: String, _ wantTitle: String, _ wantArtist: String) -> Bool {
        GeniusService.isMatch(candidateTitle: candTitle, candidateArtist: candArtist,
                              wantTitle: wantTitle, wantArtist: wantArtist)
    }

    func testSameTitleByDifferentArtistIsRejected() {
        XCTAssertFalse(matches("Danger", "Esther", "Danger", "Strajk"))
    }

    func testArtistsSharingOnlyAWordAreRejected() {
        XCTAssertFalse(matches("Blinding Lights", "The Killers", "Blinding Lights", "The Weeknd"))
    }

    func testTitleContainingTheWantedTitleIsRejected() {
        XCTAssertFalse(matches("Danger Stranger", "Strajk", "Danger", "Strajk"))
    }

    func testSameTitleAndArtistIsAccepted() {
        XCTAssertTrue(matches("Nostalgija", "Strajk", "Nostalgija", "Strajk"))
    }

    func testCaseDiacriticsAndPunctuationAreIgnored() {
        XCTAssertTrue(matches("Štrajk!", "Hladno pivo", "strajk", "Hladno Pivo"))
    }

    func testVersionSuffixAndFeatureTagAreIgnored() {
        XCTAssertTrue(matches("Song", "X", "Song - Remastered 2011", "X"))
        XCTAssertTrue(matches("Work", "Rihanna", "Work (feat. Drake)", "Rihanna"))
    }

    func testCoverIsRejected() {
        XCTAssertFalse(matches("Work (Rihanna Cover)", "Glamour", "Work", "Rihanna"))
    }

    func testAnyOneCollaboratorMatches() {
        XCTAssertTrue(matches("Under Pressure", "Queen & David Bowie", "Under Pressure", "Queen"))
        XCTAssertTrue(matches("Work", "Rihanna (Ft. Drake)", "Work", "Drake"))
        XCTAssertTrue(matches("Mila", "Coby, Senidah", "Mila", "Coby & Senidah"))
    }

    func testBareTitleDropsVersionTagsForSearch() {
        XCTAssertEqual(GeniusService.bareTitle("Under Pressure - Remastered 2011"), "Under Pressure")
        XCTAssertEqual(GeniusService.bareTitle("Work (feat. Drake)"), "Work")
        XCTAssertEqual(GeniusService.bareTitle("(Untitled)"), "(Untitled)")
    }

    func testFullyParenthesizedTitleStillMatches() {
        XCTAssertTrue(matches("(Untitled)", "X", "(Untitled)", "X"))
        XCTAssertFalse(matches("(Untitled)", "X", "(Something Else)", "X"))
    }
}

final class SpotifyLoginCodeTests: XCTestCase {
    // RFC 6238 Appendix B SHA-1 vectors, truncated to 6 digits (verified independently in Python).
    private let rfcSecret = Data("12345678901234567890".utf8)

    func testMatchesRFC6238Vectors() {
        XCTAssertEqual(SpotifyLyricsService.totp(secret: rfcSecret, time: 59), "287082")
        XCTAssertEqual(SpotifyLyricsService.totp(secret: rfcSecret, time: 1111111109), "081804")
    }

    func testDecodesPublishedSecretBytes() {
        XCTAssertEqual(SpotifyLyricsService.decodeSecret([12, 56]), "550")   // 12^9, 56^10
    }

    func testSecretXorKeyWrapsEvery33Bytes() {
        XCTAssertEqual(SpotifyLyricsService.decodeSecret(Array(repeating: 0, count: 34)),
                       "910111213141516171819202122232425262728293031323334353637383940419")
    }
}

final class SpotifyTokenResponseTests: XCTestCase {
    private func parse(_ status: Int, _ body: String) -> SpotifyLyricsService.TokenResponse {
        SpotifyLyricsService.parseToken(status: status, data: Data(body.utf8))
    }

    func testLoggedInTokenIsAccepted() {
        let body = #"{"clientId":"d8a5ed958d274c2e8ee717e6a4b0971d","accessToken":"BQ123","accessTokenExpirationTimestampMs":1761220000000,"isAnonymous":false}"#
        XCTAssertEqual(parse(200, body), .token("BQ123", expiresAt: Date(timeIntervalSince1970: 1_761_220_000)))
    }

    func testAnonymousTokenMeansCookieRejected() {
        let body = #"{"clientId":"d8a5ed958d274c2e8ee717e6a4b0971d","accessToken":"BQanon","accessTokenExpirationTimestampMs":1761220000000,"isAnonymous":true}"#
        XCTAssertEqual(parse(200, body), .cookieRejected)
    }

    // Observed 2026-10-23: an invalid sp_dc gets 401, a wrong TOTP gets 400.
    func testUnauthorizedMeansCookieRejected() {
        XCTAssertEqual(parse(401, #"{"error":{"code":401,"message":"Unauthorized","trace":"eyJ"}}"#), .cookieRejected)
    }

    func testErrorStatusMeansLoginRejected() {
        XCTAssertEqual(parse(400, #"{"error":{"code":400,"message":"Unauthorized request"}}"#), .loginRejected)
    }

    func testNonJSONMeansLoginRejected() {
        XCTAssertEqual(parse(200, "<html>Not found</html>"), .loginRejected)
    }
}

final class SpotifyLyricsParsingTests: XCTestCase {
    private func response(_ syncType: String, _ lines: [String]) -> Data {
        Data(#"{"lyrics":{"syncType":"\#(syncType)","lines":[\#(lines.joined(separator: ","))],"provider":"MusixMatch","providerLyricsId":"1","providerDisplayName":"Musixmatch","syncLyricsUri":"","isDenseTypeface":false,"alternatives":[],"language":"mk","isRtlLanguage":false,"capStatus":"NONE","isSnippet":false},"colors":{"background":-9013642,"text":-16777216,"highlightText":-1},"hasVocalRemoval":false}"#.utf8)
    }

    private func line(_ startMs: String, _ words: String) -> String {
        #"{"startTimeMs":"\#(startMs)","words":"\#(words)","syllables":[],"endTimeMs":"0"}"#
    }

    func testLineSyncedBecomesTimedLines() {
        let r = SpotifyLyricsService.parseLyrics(response("LINE_SYNCED", [line("1000", "First"), line("62500", "Second")]))
        let parsed = LRCParser.parse(r?.synced ?? "")
        XCTAssertEqual(parsed.map(\.time), [1.0, 62.5])
        XCTAssertEqual(parsed.map(\.text), ["First", "Second"])
    }

    func testSyllableSyncedUsesLineStartTimes() {
        let r = SpotifyLyricsService.parseLyrics(response("SYLLABLE_SYNCED", [line("2000", "Only")]))
        XCTAssertEqual(LRCParser.parse(r?.synced ?? "").map(\.time), [2.0])
    }

    func testUnsyncedBecomesPlainText() {
        let r = SpotifyLyricsService.parseLyrics(response("UNSYNCED", [line("0", "Секоја ноќ, секоја ноќ"), line("0", "Ја мислам на тебе")]))
        XCTAssertNil(r?.synced)
        XCTAssertEqual(r?.plain, "Секоја ноќ, секоја ноќ\nЈа мислам на тебе")
    }

    func testNoLinesIsNil() {
        XCTAssertNil(SpotifyLyricsService.parseLyrics(response("LINE_SYNCED", [])))
        XCTAssertNil(SpotifyLyricsService.parseLyrics(Data("{}".utf8)))
    }

    func testOnlyBase62TrackIdsAreLookedUp() {
        XCTAssertTrue(SpotifyLyricsService.isTrackId("03E72sqhJiHswIl17oYQdb"))
        XCTAssertFalse(SpotifyLyricsService.isTrackId(""))
        XCTAssertFalse(SpotifyLyricsService.isTrackId("120"))   // last part of a spotify:local: URI
        XCTAssertFalse(SpotifyLyricsService.isTrackId("03E72sqhJiHswIl17oYQd/"))
    }
}

final class SpotifyLoginBlockTests: XCTestCase {
    func testRejectedCookieStaysBlockedUntilTheCookieChanges() {
        let block = SpotifyLyricsService.Block.cookieRejected(cookie: "old")
        XCTAssertTrue(block.blocks(cookie: "old", now: Date().addingTimeInterval(86_400)))
        XCTAssertFalse(block.blocks(cookie: "new", now: Date()))
        XCTAssertEqual(block.warning, .cookieRejected)
    }

    func testLoginChangeBlocksForTenMinutesThenRetries() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let block = SpotifyLyricsService.Block.loginChanged(since: start)
        XCTAssertTrue(block.blocks(cookie: "any", now: start.addingTimeInterval(599)))
        XCTAssertFalse(block.blocks(cookie: "any", now: start.addingTimeInterval(601)))
        XCTAssertEqual(block.warning, .loginChanged)
    }
}
