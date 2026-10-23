# Spotify lyrics as the primary source — design

**Date:** 2026-10-23

## Goal

Show the lyrics Spotify itself shows, whenever Spotify has them. LRCLIB and Genius stay as
fallbacks. Trigger: "Sekoja Nokj" (Dope Kukjata) has lyrics in Spotify (Musixmatch, unsynced)
but none on LRCLIB, so Lyrify showed "No lyrics found."

This reverses the old "no Spotify internal endpoint" decision in `CLAUDE.md`.

## Decisions

- **Priority:** Spotify (synced *or* plain) → LRCLIB synced → LRCLIB plain → Genius.
  Spotify always wins, even when it only has plain text and LRCLIB has a synced version.
- **Auth:** the user's `sp_dc` web-player cookie, in `config.json` as `"spDc"` (file is 0600).
  Absent ⇒ the Spotify source is off and the app behaves exactly as before.
- **Token mint (verified by probe 2026-10-23, totpVer 61):**
  1. Secret: `GET https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json`,
     take the last (highest) version; decode `byte ^ ((i % 33) + 9)` per element, concatenate
     the decimal strings, use the UTF-8 bytes as the HMAC key. Cached in memory per session.
  2. `GET https://open.spotify.com/api/server-time` → `serverTime` (seconds).
  3. TOTP: RFC 6238, HMAC-SHA1, 30 s period, 6 digits, counter = serverTime / 30.
  4. `GET https://open.spotify.com/api/token?reason=transport&productType=web-player&totp=…&totpVer=…&ts=<now>`
     with `Cookie: sp_dc=…` and a browser User-Agent → `accessToken`,
     `accessTokenExpirationTimestampMs`, `isAnonymous`.
  The access token lives in memory only, reused until 60 s before expiry.
- **Lyrics:** `GET https://spclient.wg.spotify.com/color-lyrics/v2/track/{id}?format=json&market=from_token`
  with `Authorization: Bearer …` and `App-Platform: WebPlayer`.
  - `syncType` `LINE_SYNCED` / `SYLLABLE_SYNCED` → convert `lines[].startTimeMs` + `words` to an
    LRC string (`[mm:ss.xx]words`) → `LyricsResult.synced`. The existing `LRCParser`, highlight,
    and click-to-seek paths are unchanged.
  - `UNSYNCED` → `words` joined by `\n` → `LyricsResult.plain` (existing estimated auto-scroll).
  - 404 ⇒ Spotify has no lyrics ⇒ fall through.
- **Track ID:** from AppleScript (`SpotifyTrackInfo.trackId`) and, for preload, from the Web API
  queue item's `id` (added to `NextTrack`). Only valid 22-char base62 IDs are sent; local files
  etc. skip Spotify.
- **Cache key:** `LyricsService`'s key gains the track ID.

## Components

- `SpotifyLyricsService.swift` (new) — `fetch(trackId:) -> LyricsResult?` (blocking; runs on the
  caller's queue, i.e. `fetchQueue` or the Web API queue, never main or the GCD pool). Owns the
  secret cache, token cache (NSLock-guarded; minting happens under the lock so two callers never
  double-mint), and the warning state. Pure, unit-tested helpers: `decodeSecret`, `totp`,
  `parseToken`, `parseLyrics`, `isTrackId`.
- `SpotifyConfig` — add `spDc`.
- `LyricsService.fetchSync` — new `trackId` parameter; Spotify is tried first (after kicking off
  the concurrent LRCLIB search, so a Spotify miss costs no extra wait). A hit is returned and
  cached immediately.
- `SpotifyWebAPI.NextTrack` — add `trackId`; preload passes it through.
- `LyricsViewModel` — passes `trackId`; publishes `spotifyWarning` after each fetch.
- `ContentView` — warning icon (below).

## Failure handling

| Situation | Behavior | Warning |
|---|---|---|
| No `spDc` | Skip Spotify | none |
| Network error / timeout | Skip this track, try again next track | none |
| Token response `isAnonymous: true` | Skip Spotify until the `spDc` value in `config.json` changes | `cookieRejected` |
| Token response non-200 (stale TOTP secret) | Re-download the secret once and retry; if still failing, skip Spotify for 10 min | `loginChanged` |
| Lyrics 401 | Mint a fresh token, retry once; then fall through | none |
| Lyrics 404 / other | Fall through | none |

A successful token mint clears the warning. `config.json` is re-read on every mint, so a new
cookie is picked up on the next track change.

## Warning UI

A yellow `exclamationmark.triangle.fill` at the leading edge of the controls bar (the trailing
edge holds the scroll-speed button). Shown only while `spotifyWarning != nil`.

- `cookieRejected` — tooltip: "Spotify lyrics paused: your sp_dc cookie expired or was signed
  out. Click to open config.json." Click opens `config.json` in the default editor.
- `loginChanged` — tooltip: "Spotify lyrics paused: Spotify changed its web-player login.
  Lyrify needs an update; using LRCLIB meanwhile." No click action.

## Testing

- Unit (no network): TOTP against RFC 6238 SHA-1 vectors (6-digit truncation: T=59 → 287082,
  T=1111111109 → 081804); `decodeSecret` on a small hand-computed array; `parseLyrics` for
  LINE_SYNCED (LRC round-trips through `LRCParser` with correct times), UNSYNCED, missing
  `lyrics`; `parseToken` for valid / anonymous / error bodies; `isTrackId`; `NextTrack.trackId`.
- Manual: "Sekoja Nokj" shows Spotify's plain lyrics; a synced Spotify song highlights and seeks;
  a bogus `spDc` shows the warning and falls back to LRCLIB; fixing it clears the warning on the
  next track; removing `spDc` restores the old behavior.

## Setup (goes into CLAUDE.md)

open.spotify.com (logged in) → DevTools → Application/Storage → Cookies → copy `sp_dc` →
`config.json` → `"spDc": "…"`. Lasts ~1 year; needs replacing after sign-out, "Sign out
everywhere", or a password change.

## Risks

- Unofficial endpoint, against Spotify's ToS; personal use only.
- Depends on `xyloflake/spot-secrets-go` tracking Spotify's secret rotations (last update
  2026-01-26). If it goes stale, the `loginChanged` warning shows and LRCLIB takes over.
