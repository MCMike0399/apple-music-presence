# Apple Music Presence

Shows what you are playing in **Apple Music** as a Discord *"Listening to"* status,
with the real album cover, a progress bar and a **Play on Apple Music** button.

A single-player, macOS-only re-implementation of the idea behind
[Music Presence](https://github.com/ungive/discord-music-presence), written in Swift
with no third-party dependencies. It lives in the menu bar.

## What it does

- **Instant updates.** Music.app broadcasts track and play/pause changes through a
  distributed notification; the app reacts to those and only uses AppleScript to read
  the playback position (and, on a slow poll, to detect seeks).
- **Correct cover art.** Looks the track up in the Apple Music catalog (same API the
  web player uses, with its public token scraped from `music.apple.com`), scores the
  hits against title / artist / album / duration, and falls back to the iTunes Search
  API. Images come from Apple's own CDN, which Discord proxies. If nothing matches
  you get the Apple Music logo, never a wrong cover.
- **"Listening to …"** activity type with a live progress bar. The header can read
  *Listening to Apple Music*, *Listening to \<artist\>* or *Listening to \<song\>*.
- **Buttons and links.** "Play on Apple Music" button plus clickable title / artist /
  album text where Discord supports it.
- **Paused music** is hidden by default (like the original); toggle it to keep the
  presence up without a timer.
- **Privacy filter** for personal radio stations ("Someone's Station") and cleanup of
  " - Single" / " - EP" album suffixes.
- **Menu bar icon can be hidden.** The app keeps running headless; open it again
  from /Applications or Spotlight to get the icon back.
- Never launches Music.app, never touches its playback.

## Build and run

Requires macOS 14+ and the Xcode Command Line Tools (Swift 5.9+; no Xcode needed).

```sh
make run          # debug build, runs in the foreground (logs to stderr)
make app          # release build → build/Apple Music Presence.app
make install      # copies the bundle into /Applications
```

On first launch macOS asks for permission to control Music (Automation). The app
does not work without it.

The menu bar icon exposes the everyday toggles. Everything else lives in
`~/Library/Application Support/AppleMusicPresence/settings.json`:

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch |
| `discordApplicationId` | `1247654840780460125` | Discord app whose name shows as "Listening to …". Create your own at discord.com/developers to customise it |
| `displayType` | `player` | `player` / `artist` / `title` |
| `showPausedMedia` | `false` | Keep the presence while paused |
| `showAlbumName` | `true` | Album as the cover's hover text |
| `showButtons` | `true` | "Play on Apple Music" button |
| `showPlayerLogo` | `true` | Small Apple Music logo on the cover |
| `cleanAlbumSuffixes` | `true` | Strip " - Single" / " - EP" |
| `hidePersonalStations` | `true` | Hide "…'s Station" radio |
| `countryCode` | `null` | Storefront for lookups and links (defaults to your locale) |
| `pollIntervalSeconds` | `2` | Position poll interval |
| `showMenuBarIcon` | `true` | Menu bar icon. "Hide Menu Bar Icon…" in the menu sets it to false; launching the app again brings it back |

Logs: `~/Library/Application Support/AppleMusicPresence/presence.log`.

## Layout

```
Sources/AppleMusicPresence/
  main.swift                 app bootstrap, single-instance guard
  MusicMonitor.swift         Music.app notifications + AppleScript position reads
  ArtworkResolver.swift      Apple Music catalog + iTunes Search lookups, scoring, cache
  PresenceBuilder.swift      NowPlaying → Discord activity payload
  PresenceCoordinator.swift  change detection, seek detection, settings application
  DiscordIPC.swift           Discord IPC socket client with reconnect
  StatusItemController.swift menu bar UI
  Settings.swift / NowPlaying.swift / Log.swift
Scripts/build-app.sh         wraps the release binary in a signed .app bundle
```

## License

BSD-3-Clause.
