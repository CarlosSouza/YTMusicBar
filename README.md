# YTMusicBar

A standalone YouTube Music client for the macOS 14+ menu bar, built with SwiftUI, `ytmusicapi`, `yt-dlp` and `mpv`. The architecture follows the Omarchy `omarchy-ytmusic` widget (Quickshell UI plus local mpv playback) and reuses the local packaging approach of [UsageBar](https://github.com/CarlosSouza/UsageBar).

The catalog is queried through `ytmusicapi`'s local protocol. Playback uses a single persistent `mpv` that resolves the audio itself through `ytdl_hook` (pointed at the Homebrew `yt-dlp`) and keeps the track queue. There is no Safari, Chrome, WebView, Apple Events or embedded login.

## Features

- Everything lives in the menu bar popover, with no windows: player with artwork, draggable progress, transport and volume; search; Queue, Library, Playlists and Results tabs in a scrollable list; Settings and Connect as internal pages.
- Local background playback by a single mpv, reused across clicks.
- Playing a song queues the list it was clicked in (library or results) starting from that song; playlists are queued whole. Previous and next move through the queue.
- The Queue tab shows played tracks dimmed, the current one highlighted and the upcoming ones; clicking a row jumps to it.
- Track name in the menu bar, with artwork, artist, album and progress in the popover.
- Play/pause, previous (restarts the track after 3 s), next, drag to seek.
- Like or unlike the current track, with the initial state fetched from the server.
- mpv volume and mute.
- No Apple Events and no macOS Automation permission.

## Build

Requirements: macOS 14+, Command Line Tools or Xcode with Swift 6, and Homebrew with `mpv` and `yt-dlp`. `ytmusicapi` lives in a local venv that the build copies into the app bundle.

```sh
brew install mpv yt-dlp
git clone https://github.com/CarlosSouza/YTMusicBar.git
cd YTMusicBar
python3 -m venv .ytmusic-venv
.ytmusic-venv/bin/pip install ytmusicapi
bash scripts/build-app.sh
open dist/YTMusicBar.app
```

The script produces an ad hoc signed app for local use. Public distribution still needs a Developer ID, notarization and a proper icon.

## First run

1. Open YTMusicBar from the menu bar.
2. Click **Configure access…**. The page explains each step, opens YouTube Music and takes the headers pasted directly into the popover. No Terminal needed.
3. After saving, use search or the Library tab and click a song; the controls appear in the popover and the title in the menu bar.

The headers are stored in `~/Library/Application Support/YTMusicBar/ytmusic-auth.json` and used only by the local bridge. The browser is not needed after setup. They are sensitive credentials and must not be shared.

## Library, playlists and search

The popover has Library and Playlists tabs; the Results tab appears after a search and the Queue tab while something is loaded. Clicking a song queues the whole list it was in, starting from it; clicking a playlist loads every available track. When the queue ends, the last track stays visible, paused, and the play button restarts it. Rapid clicks are serialized by the bridge and the last one wins, always with a single `mpv` process. Closing the popover keeps playing. Quit (or Cmd-Q) stops mpv before the process exits.

Player state lives in `~/Library/Application Support/YTMusicBar/` (`queue.json`, `queue.m3u`, `mpv.pid`, `player.lock`); the mpv IPC socket is `ytmusicbar-mpv.sock` in the user's temporary directory.

## Verify

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/ytmusicbar-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/ytmusicbar-modules \
swift run \
  --scratch-path /private/tmp/ytmusicbar-tests \
  --cache-path /private/tmp/ytmusicbar-cache \
  --disable-sandbox \
  YTMusicCoreChecks

plutil -lint dist/YTMusicBar.app/Contents/Info.plist
codesign --verify --deep --strict dist/YTMusicBar.app
```

The checks cover URLs, progress estimation, duration formatting, queue ids, the Python bridge and the presence of `mpv`/`yt-dlp`.

## Known limits

- `ytmusicapi` and `yt-dlp` depend on YouTube's internal APIs and protocols and may need updates.
- Authentication headers can expire and need to be redone.
- The app does not bypass ads, DRM, geographic restrictions or YouTube Premium requirements.
- The local build is ad hoc signed and not ready for distribution outside this machine.

## Layout

- `Sources/YTMusicCore`: playback state, URLs and testable logic.
- `Sources/YTMusicBar/LocalMusicPlayer.swift`: Swift bridge for catalog and local playback.
- `scripts/ytmusic_bridge.py`: `ytmusicapi`, single-mpv lifecycle and queue over IPC.
- `Sources/YTMusicBar/App.swift`: the whole popover (player, catalog, settings, access setup).
- `Sources/YTMusicBar/Store.swift`: observable state, active tab, search, polling and graceful shutdown.
- `scripts/build-app.sh`: local `.app` packaging.
- `Tests/YTMusicCoreTests`: offline checks.
- `docs/architecture.md`: architecture notes (in Portuguese).

## Credits and license

Licensed under the [MIT License](LICENSE).

The design follows [omarchy-ytmusic](https://github.com/leoriohub/omarchy-ytmusic) by rlimberger, itself derived from Omarchy-Spotify, both MIT licensed: Copyright (c) 2026 Omarchy Spotify contributors, Copyright (c) 2026 rlimberger.
