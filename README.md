# YTMusicBar

A standalone YouTube Music client for the macOS 14+ menu bar, built with SwiftUI, `ytmusicapi`, `yt-dlp` and `mpv`. The architecture follows the Omarchy `omarchy-ytmusic` widget (Quickshell UI plus local mpv playback) and reuses the local packaging approach of [UsageBar](https://github.com/CarlosSouza/UsageBar).

The catalog is queried through `ytmusicapi`'s local protocol. Playback uses a single persistent `mpv` that resolves the audio itself through `ytdl_hook` (pointed at the Homebrew `yt-dlp`) and keeps the track queue. There is no Safari, Chrome or Apple Events, and playback never goes through a web view: a `WKWebView` is used only to sign in, so WebKit owns the session cookies instead of the app holding a copy.

## Features

- Everything lives in the menu bar popover, the sign-in window being the only exception: player with artwork, draggable progress, transport and volume; search; Queue, Library, Playlists, Para você and Results tabs in a scrollable list; Settings and Connect as internal pages.
- The `Para você` tab mirrors the YouTube Music home rows (Tocar de novo, Meu mix, Quick picks, Recaps...), so the playlists and mixes the service generates for the account show up next to the ones saved in the library.
- A radio button rebuilds the queue from the track playing now, using the endless radio YouTube Music builds from that song. Radio and mix queues top themselves up before they run out, so they keep going.
- Local background playback by a single mpv, reused across clicks.
- Playing a song queues the list it was clicked in (library or results) starting from that song; playlists are queued whole. Previous and next move through the queue.
- The Queue tab shows played tracks dimmed, the current one highlighted and the upcoming ones; clicking a row jumps to it.
- Track name in the menu bar, with artwork, artist, album and progress in the popover.
- Play/pause, previous (restarts the track after 3 s), next, drag to seek.
- Like or unlike the current track, applied to the heart immediately and reconciled with the server in the background.
- Save a playlist or album to the library from its context menu, and remove it from the Playlists tab, where everything already is the library.
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

The script produces an ad hoc signed app for local use. Public distribution still needs a Developer ID and notarization.

## First run

1. Open YTMusicBar from the menu bar.
2. Click **Configure access…** and press **Entrar com o Google**. The login happens in a window owned by the app, using a Safari user agent, because WebKit's own agent has no `Safari` token and Google refuses to sign in with it. The cookies stay in WebKit's cookie store, so nothing has to be copied by hand.
3. A manual import remains available: copy the request headers of a `/browse` call from any browser network panel (or a `Copy as cURL` command, or the bare `cookie` value) and press **Importar da área de transferência**.
4. The credentials are written to disk only after the app confirms the session is signed in, so a stale copy is rejected instead of silently saved. On success the account name appears in Settings, where **Reconfigurar…** and the expiry warning live.
5. After saving, use search or the Library tab and click a song; the controls appear in the popover and the title in the menu bar.

The headers are stored in `~/Library/Application Support/YTMusicBar/ytmusic-auth.json` and used only by the local bridge. Only the cookie and the account index are kept; the `SAPISIDHASH` is regenerated on every request. They are sensitive credentials and must not be shared.

## Library, playlists and search

The popover has Library and Playlists tabs; the Results tab appears after a search and the Queue tab while something is loaded. Clicking a song queues the whole list it was in, starting from it; clicking a playlist loads every available track. When the queue ends, the last track stays visible, paused, and the play button restarts it. Rapid clicks are serialized by the bridge and the last one wins, always with a single `mpv` process. Closing the popover keeps playing. Quit (or Cmd-Q) stops mpv before the process exits.

## Para você and radio

`Para você` opens as an index of the YouTube Music home rows, each with an icon, a title and how much it holds, because the popover is too short to scroll through all of them. The icon comes from the words in the row title, falling back to a generic one, since those titles are generated per account. Opening a row shows its contents. Rows mix songs, playlists, mixes and albums, and each entry is mapped to what it really is: a song plays with the row it was clicked in, a playlist, mix or recap loads through `get_playlist`, and an album through `get_album`. A row that carries both a videoId and an `RDAMVM` playlist id is a song, because that id is the radio of the song and `get_playlist` rejects it.

The radio button next to the transport rebuilds the queue from the track playing now, and any song row offers the same action in its context menu. It asks for 150 tracks and YouTube usually returns more (around 200 in practice); the radio is rebuilt each time, so it differs between runs. The queue tops itself up before it runs out, so a radio keeps going.

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

.ytmusic-venv/bin/python scripts/ytmusic_bridge.py --selftest

plutil -lint dist/YTMusicBar.app/Contents/Info.plist
codesign --verify --deep --strict dist/YTMusicBar.app
```

The checks cover URLs, progress estimation, duration formatting, queue ids and the presence of `mpv`/`yt-dlp`. `--selftest` covers the auth import: header block, cURL command, bare cookie and the rejected inputs. Both run as part of `scripts/build-app.sh`.

## Known limits

- `ytmusicapi` and `yt-dlp` depend on YouTube's internal APIs and protocols and may need updates.
- Opening a playlist or a personalized mix queues about 400 tracks at first, because the personalized mixes are effectively endless and asking for all of them never returns. A radio or a mix then tops itself up as it plays, five tracks before the end, up to 2000 tracks; a finite playlist simply stops growing once it is exhausted.
- Starting a track is not instant: mpv resolves the stream with `yt-dlp` first, which takes a second or two. The progress bar shows a spinner during that window instead of counting from zero, and the row keeps its spinner until audio actually starts.
- Authentication cookies expire. Signing in happens in a `WKWebView` the app owns, so the session lives in WebKit's cookie store. When the stored copy goes stale the app reloads YouTube Music in an offscreen web view, lets the page rotate `__Secure-3PSIDTS` itself, and reconnects on its own; only if WebKit has no session either does it ask for a new sign-in.
- The library list is eventually consistent server side: after saving or removing a playlist it takes a moment to show up, so the app waits two seconds before reloading it.
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
