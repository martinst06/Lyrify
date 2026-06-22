# Next-track lyric preload — design

**Date:** 2026-06-22

## Goal

Eliminate the "Loading…" gap on track change by preloading the **next** song's lyrics.
Spotify's AppleScript API can't see the queue, so use the Spotify Web API to learn the
next track, then warm `LyricsService`'s existing cache. **No UI change** (silent preload).

## Decisions

- **Auth:** Authorization Code + PKCE (no client secret). Scope `user-read-playback-state`.
- **Callback:** loopback `http://127.0.0.1:8888/callback`, caught by a one-shot `NWListener`.
- **Client ID:** read from `~/Library/Application Support/Lyrify/config.json` (`{ "clientId": "…" }`). Not committed.
- **Tokens:** `~/Library/Application Support/Lyrify/tokens.json`, `chmod 0600`.
- **Next track:** `GET /v1/me/player/queue` → `queue[0]` (folds manual queue + context order).
- **Depth:** just `queue[0]` (immediate next).
- **Trigger:** piggyback existing track-change detection — one queue fetch per song.

## Components

- `SpotifyConfig.swift` — loads clientId; absent ⇒ feature is a no-op.
- `SpotifyAuth.swift` — PKCE flow (first run, opens browser once), token store + refresh,
  `accessToken() -> String?`.
- `SpotifyWebAPI.swift` — `fetchNextTrack() -> NextTrack?` from `/me/player/queue`; runs on a
  dedicated serial queue; 401 ⇒ refresh + retry once; 204/empty/error ⇒ nil.
- `LyricsViewModel` — after detecting a track change, enqueue a preload on the webapi queue:
  fetch next track → if changed since last, `LyricsService.fetchSync(next…)` to warm the cache.

## Isolation / failure

The Web API layer only warms the cache. No config, auth failure, browser closed, revoked
token, no active device, or any network error ⇒ skip that preload cycle. The existing
AppleScript → LRCLIB on-demand path is untouched and remains the source of truth. Cache key is
`title|artist|album|durationMs`; if Web-API metadata doesn't match AppleScript's exactly, the
preload misses and we fall back to today's behavior (best-effort speedup, never a regression).
All blocking work stays on dedicated queues — never the detection loop, position loop, or main.

## Testing

- Unit: PKCE challenge derivation (base64url(SHA256(verifier))), token-response parsing,
  `queue[0]` parsing.
- Manual: configure clientId → one-time browser approval → confirm next song's lyrics appear
  with no "Loading…".

## One-time setup

Spotify Developer app → Client ID into `config.json` → add `http://127.0.0.1:8888/callback`
as a Redirect URI → launch Lyrify → approve in browser once.
