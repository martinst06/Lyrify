# Lyrify

Floating synced lyrics window for Spotify on macOS. Built with SwiftUI.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- Synced lyrics that follow playback in real time
- Frosted glass floating window — always on top, never steals focus
- Playback controls (previous, play/pause, next) with spacebar shortcut
- Fetches lyrics from LRCLIB — works for songs Spotify doesn't have lyrics for
- Resizable to any size, lives in a corner while you work

## Requirements

- macOS 13+
- Spotify desktop app
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/YOUR_USERNAME/Lyrify.git
cd Lyrify
swift build -c release
sudo cp .build/release/Lyrify /usr/local/bin/lyrify
sudo chmod +x /usr/local/bin/lyrify
```

## Run

```bash
lyrify
```

Grant **Automation** permission when macOS asks (needed to read track info from Spotify).

### Auto-start on login

```bash
cp LaunchAgent/com.user.lyrify.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.lyrify.plist
```

## Usage

| Action | How |
|--------|-----|
| Play / Pause | Spacebar (when Lyrify is focused) |
| Previous track | Click ⏮ |
| Next track | Click ⏭ |
| Resize | Drag any window edge |
| Move | Drag anywhere on the window |

## Lyrics source

Lyrics are fetched from [LRCLIB](https://lrclib.net) — a free, community-maintained synced lyrics database. If a song isn't there, the app shows "No lyrics found."

## Customization

Edit `Sources/Lyrify/ContentView.swift` to change font, colors, and spacing. Rebuild with `swift build -c release` after any changes.

## Privacy

No data is collected. The app only communicates with:
- Spotify (via AppleScript, local only)
- lrclib.net (to fetch lyrics)
