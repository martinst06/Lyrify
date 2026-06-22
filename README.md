# Lyrify

Floating synced lyrics window for Spotify on macOS. Built with SwiftUI.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- Synced lyrics that follow playback in real time
- Frosted glass floating window — always on top, never steals focus
- Click any lyric line to jump Spotify playback to that point
- Playback controls (previous, play/pause, next) with spacebar shortcut
- Resizable, lives in a corner while you work
- Optional: preloads the next song's lyrics so track changes are instant (see setup below)

## Requirements

- macOS 13+
- Spotify desktop app
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone git@github.com:martinst06/Lyrify.git
cd Lyrify
./build-app.sh
```

`build-app.sh` compiles the app and drops `Lyrify.app` on your Desktop. Double-click it — no terminal needed.

Grant **Automation** permission when macOS prompts (needed to read track info from Spotify).

### Optional: auto-start on login

```bash
cp LaunchAgent/com.user.lyrify.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.lyrify.plist
```

> Note: the LaunchAgent runs `/usr/local/bin/lyrify`. Install the binary there if you use this:
> `sudo cp .build/release/Lyrify /usr/local/bin/lyrify`

### Optional: instant track changes (preload next song's lyrics)

By default each song's lyrics load on demand, so you briefly see "Loading…" when a track changes. Lyrify can instead preload the *next* song's lyrics in the background so changes are instant. This needs the Spotify Web API (Spotify's AppleScript interface can't see the queue), which means a one-time login.

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and copy its **Client ID**.
2. In that app's settings, add a **Redirect URI**: `http://127.0.0.1:8888/callback`
3. Create `~/Library/Application Support/Lyrify/config.json`:
   ```json
   { "clientId": "YOUR_CLIENT_ID" }
   ```
4. Launch Lyrify and play a song. A browser tab opens **once** to authorize read-only playback access. After that it's silent — tokens are stored locally (`tokens.json`, owner-only) and refresh automatically.

Leave `config.json` out and the feature stays off — the app works exactly as before.

## Usage

| Action | How |
|--------|-----|
| Play / pause | Spacebar (when Lyrify is focused), or the center button |
| Previous / next track | ⏮ / ⏭ buttons |
| Jump to a lyric | Click any line — seeks Spotify to that timestamp |
| Resize | Drag any window edge |
| Move | Drag anywhere on the window |

## Customization

Edit `Sources/Lyrify/ContentView.swift` for fonts, colors, and spacing. After any change, rebuild with:

```bash
./build-app.sh
```

## Lyrics source

Lyrics are fetched from [LRCLIB](https://lrclib.net) — a free, community-maintained synced lyrics database. The app searches for a synced version first; if none exists, it falls back to plain text or "No lyrics found."

## Privacy

No data is collected. The app only communicates with:
- Spotify (via AppleScript, local only)
- lrclib.net (to fetch lyrics)
- *(only if you enable preload)* accounts.spotify.com / api.spotify.com — to read your playback queue. Read-only access (`user-read-playback-state`); tokens are stored locally on your machine and never sent anywhere else.
