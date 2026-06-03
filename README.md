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
