# Spotify Now Playing for OpenLogi

An [OpenLogi](https://github.com/AprilNEA/OpenLogi) key module for the Logitech MX
Creative Keypad. Any keypad key you bind to it shows what Spotify is playing,
and pressing that key plays or pauses Spotify.

- **Playing:** the album art, with the title and artist over a dark shade at
  the bottom.
- **Paused:** the same tile in grayscale, dimmed, with a white play triangle
  in a dark circle at the top: the action a press takes.
- **Spotify not running, or running with nothing loaded:** Spotify's app icon,
  centered on black, so the key always shows something. The icon is read at
  runtime from the Spotify app installed on your Mac. If it cannot be read, a
  plain dark tile with a play triangle and the word Spotify stands in.

Pressing the key when Spotify is running toggles play and pause. When Spotify
is not running, a press launches it and starts playing as soon as it is ready
(it keeps trying for about 10 seconds).

Not affiliated with, endorsed by, or sponsored by Spotify. Spotify is a
trademark of Spotify AB. No Spotify logo, artwork, or other brand asset is
part of this project.

## Requirements

- macOS 15 or later.
- The Spotify desktop app.
- An OpenLogi build with key modules (module protocol 1).
- The Command Line Tools (`xcode-select --install`) for `swiftc`, to build.
  There are no other dependencies.

## Install

Build it:

```sh
zsh build.sh
```

This writes `spotify-module` next to `module.toml`. OpenLogi needs only those
two files. Copy them into a folder of their own in OpenLogi's modules folder:

```sh
mkdir -p ~/.config/openlogi/modules/spotify
cp module.toml spotify-module ~/.config/openlogi/modules/spotify/
```

A development build of OpenLogi reads `~/.config/openlogi-dev/modules/`
instead.

## Turn it on and bind a key

1. In OpenLogi's Settings, open the Modules section and tick **Spotify Now
   Playing**. OpenLogi starts the module while it is ticked.
2. In the keypad's bindings, choose **Spotify Now Playing** as the action for
   any key, on any page. Bind it to more than one key if you like; they all
   show the same tile, unless all nine keys of a page are bound (see below).

The same settings in `config.toml` (use your keypad's own device key):

```toml
[modules."com.typ.openlogi.spotify"]
enabled = true

[devices."serial:YOUR-KEYPAD-SERIAL".bindings]
gridMiddle = { Module = "com.typ.openlogi.spotify" }
```

## Album art across all nine keys

Bind all nine keys of one page to Spotify Now Playing (for example on a
per-app profile for Spotify, so the keypad turns into the album cover while
Spotify is in front) and the art spreads across the whole grid, one piece per
key:

- **Playing:** the art only, no title or artist.
- **Paused:** the whole picture in grayscale and dimmed, with the play button
  on the center key.
- **Spotify not running, or nothing loaded:** the app icon tile on the center
  key; the other eight keys go black.
- **New track:** the new art fills in one key at a time, top left to bottom
  right. Play and pause, and switching to the page, redraw all nine at once.

Any of the nine keys plays or pauses, as a single key does. A page with fewer
than nine keys bound keeps one full tile per key.

The art covers the keys and the gaps between them, so a straight line in the
cover stays straight from key to key; the strips under the gaps are not shown.
Two optional settings tune it:

| Setting | Default | Meaning |
| --- | --- | --- |
| `mosaic_gap_percent` | `25` | The gap between keys as a percentage of a key's side (0 to 60). Raise it if lines look broken at the gaps, lower it if they look stretched. 0 cuts the art with no gaps. |
| `mosaic_stagger_ms` | `90` | Milliseconds between keys when a new track fills in (0 to 1000). 0 draws all nine at once. |

A Spotify profile with all nine keys on page 1, in `config.toml`:

```toml
[devices."serial:YOUR-KEYPAD-SERIAL".per_app_bindings."com.spotify.client"]
gridTopLeft = { Module = "com.typ.openlogi.spotify" }
gridTopMiddle = { Module = "com.typ.openlogi.spotify" }
gridTopRight = { Module = "com.typ.openlogi.spotify" }
gridMiddleLeft = { Module = "com.typ.openlogi.spotify" }
gridMiddle = { Module = "com.typ.openlogi.spotify" }
gridMiddleRight = { Module = "com.typ.openlogi.spotify" }
gridBottomLeft = { Module = "com.typ.openlogi.spotify" }
gridBottomMiddle = { Module = "com.typ.openlogi.spotify" }
gridBottomRight = { Module = "com.typ.openlogi.spotify" }

[modules."com.typ.openlogi.spotify".settings]
mosaic_gap_percent = 25
mosaic_stagger_ms = 90
```

Use your keypad's own device key. On a later page, name the keys
`"page2:gridTopLeft"` and so on. A setting that is not a number falls back to
its default, one out of range is clamped, and either puts one warning in
OpenLogi's log. Changing the settings restarts the module.

## The Automation prompt

The module reads Spotify and plays or pauses it through AppleScript, so the
first time it talks to Spotify, macOS asks whether to allow control of
Spotify. Click OK. macOS usually names the app that started the module
(OpenLogi's agent) in that prompt rather than the module itself.

Until the prompt is answered, reads time out and the key keeps its last tile;
the module starts over with a fresh script after each timeout, so it picks up
as soon as you answer. If you clicked Don't Allow, OpenLogi's log shows
`not allowed to control Spotify ... [-1743]`. Turn it back on in System
Settings > Privacy & Security > Automation, under the app that asked, then
toggle Spotify on.

Rebuilding the module can make macOS ask again.

## Uninstall

1. Untick the module in OpenLogi's Settings and remove it from any key.
2. Delete its folder: `rm -r ~/.config/openlogi/modules/spotify`.
3. Optionally delete its tile cache: `rm -r ~/Library/Caches/com.typ.openlogi.spotify`.
4. Optionally remove the `[modules."com.typ.openlogi.spotify"]` table from
   OpenLogi's `config.toml`, and the Automation permission in System Settings.

## How it behaves

- **Event driven.** Spotify's `com.spotify.client.PlaybackStateChanged`
  notification and Spotify's launch are wake-ups only: each one, with bursts
  merged into one read per 250 ms, triggers a single AppleScript read of the
  player state and current track, which stays the authority. Spotify quitting
  switches the keys to the app icon tile at once.
- **Reconcile.** Every 30 seconds the module reads Spotify again and sends the
  current tile even when nothing changed, so a restarted keypad panel gets it
  back. A tile drawn without its album art (the download failed) is rendered
  again instead, so the art gets another chance (at most once a minute).
- **Idle when unbound.** With no key bound to it, the module keeps running but
  reads nothing and draws nothing until a key is bound again.
- **Sizes.** Tiles are drawn at the size OpenLogi gives for the bound keys
  (118 pixels on the MX Creative Keypad).
- **Render cache.** `~/Library/Caches/com.typ.openlogi.spotify/`, one PNG per
  track, playing or paused, and size, named by a SHA-256 of those plus a
  design version, plus one each for the app icon tile and its stand-in, and
  one per key of a mosaic (track, art, playing or paused, size, gap, and
  position). A tile seen before is sent straight from the cache. Past 300 tiles the least
  recently used are deleted down to 250. Delete the folder any time, for
  example after Spotify changes its icon.
- **Timeouts.** Spotify reads time out after 5 seconds, album art downloads
  after 5 seconds, so a busy Spotify or a slow network cannot hang the keys
  for long.
- **Never launches Spotify on its own.** It reads Spotify only while Spotify
  is running; only a key press launches it.

## Development

`Sources/main.swift` is the whole module. Diagnostics go to stderr, which
OpenLogi keeps in its log; stdout carries protocol messages only.

Render one tile to a PNG without Spotify or OpenLogi:

```sh
./spotify-module --preview out.png --title "Midnight City" --artist "M83" \
    --artwork ~/Pictures/cover.jpg [--paused] [--size 118]
./spotify-module --preview out.png --app-icon     # the Spotify-not-running tile
./spotify-module --preview out.png                # its stand-in
```

Try the module without OpenLogi: `tools/fake_host.py` starts it, sends
`hello` and `keys`, prints everything it sends back, and saves the images to a
folder. `--press` sends a key press, which plays or pauses your real Spotify.

```sh
python3 -I tools/fake_host.py [--size 118] [--slots 1] [--wait 3] [--press] [--out DIR]
```

Set `SPOTIFY_MODULE_CACHE_DIR` to use another cache folder.

Tests:

```sh
zsh tests/run.sh
```

This builds a test binary with a fake Spotify (`tests/FakeSpotify.swift`, never
part of the real build) into a temporary folder and drives it through the fake
host: the protocol, the tiles, presses, reconciles, and shutdown. It never
touches the Spotify app or OpenLogi.

## License

MIT. See [LICENSE](LICENSE).
