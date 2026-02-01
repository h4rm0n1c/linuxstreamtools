# streamlinkbgm

Background music automation for Streamlink + MPV. The primary entry point is `streamlink_3.sh`, which creates a PipeWire/PulseAudio null sink for MPV, exposes a remapped source for OBS, and manages playback in a detached `screen` session. Optional: use `bgm_tray.sh` to control playback from a YAD tray menu.

## Requirements

- Linux with PipeWire or PulseAudio (`pactl`)
- `mpv`
- `streamlink` (required by MPV for YouTube/stream URLs)
- `screen`
- `jq`
- `socat`
- Optional: `yad` (for the tray controller)

## Install prerequisites (Debian/Devuan)

```bash
sudo apt update
sudo apt install mpv streamlink screen jq socat pipewire-pulse yad
```

If you are using PulseAudio instead of PipeWire, install `pulseaudio` instead of `pipewire-pulse`.

## Install

1. Make the script executable:
   ```bash
   chmod +x streamlink_3.sh
   ```
2. (Optional) Add it to your PATH, or create a symlink in `~/bin`:
   ```bash
   ln -s "$(pwd)/streamlink_3.sh" ~/bin/streamlink_3.sh
   ```

## Quick start

Start the background music pipeline:

```bash
./streamlink_3.sh start
```

`start` already launches the track watcher in the background (detached from the launching terminal), so you do **not** need to call `watch` separately for normal use. If you do need to run the watcher manually, keep it in the background so it does not block your shell or scripts:

```bash
./streamlink_3.sh watch >/tmp/streamlinkbgm.watch.log 2>&1 &
```

Stop it when you are done:

```bash
./streamlink_3.sh stop
```

Check status:

```bash
./streamlink_3.sh status
```

For a longer setup guide, see `docs/streamlinkbgm.md` in the repository root.

## Configuration files

The script stores settings in your XDG config directory (defaults to `~/.config`). You can override the location by exporting `XDG_CONFIG_HOME`:

- `streamlink_bgm_url` — the last fixed URL used with `seturl`.
- `streamlink_bgm_sources` — one URL per line (playlists or videos). Blank lines and `#` comments are ignored.
- `streamlink_bgm_mode` — set to `daily` for a deterministic daily pick, or anything else for random.
- `streamlink_bgm_listen_sink` — optional sink name/number for local listening.

## Common commands

Set a fixed URL and restart MPV:

```bash
./streamlink_3.sh seturl "https://www.youtube.com/watch?v=..."
```

Add a URL to the sources list:

```bash
./streamlink_3.sh addurl "https://www.youtube.com/playlist?list=..."
```

List sources:

```bash
./streamlink_3.sh listsources
```

Switch between random and daily mode:

```bash
./streamlink_3.sh setmode daily
```

## Local listening (optional)

If you want to hear the BGM locally while still outputting the remapped OBS source, pick a sink:

```bash
./streamlink_3.sh sinks
./streamlink_3.sh listen 2   # or use a sink name
```

The listen loopback is pinned to the chosen sink; if that sink disappears (USB headset unplugged, etc.), re-run `listen` after it returns.

Disable local listening:

```bash
./streamlink_3.sh unlisten
```

## Playback controls

These commands talk to MPV over its IPC socket:

```bash
./streamlink_3.sh next
./streamlink_3.sh prev
./streamlink_3.sh shuffle
./streamlink_3.sh pause
./streamlink_3.sh resume
./streamlink_3.sh toggle
./streamlink_3.sh vol -5
./streamlink_3.sh what
```

## Tray controller (optional)

`bgm_tray.sh` provides a YAD tray menu for quick control and URL management.

### Requirements

- `yad`
- `mpv_ipc_send` (used by the tray menu to talk to MPV). Put it in `~/.local/bin/mpv_ipc_send` or set `SENDER=/path/to/mpv_ipc_send` before starting the tray script.

### Run

```bash
./bgm_tray.sh
```

### Path overrides

The tray script follows XDG paths and allows overrides:

- `XDG_CONFIG_HOME` (defaults to `~/.config`)
- `SOURCES_FILE` (defaults to `$XDG_CONFIG_HOME/streamlink_bgm_sources`)
- `BGM_CTL` (defaults to the local `streamlink_3.sh`)
- `SENDER` (defaults to `~/.local/bin/mpv_ipc_send`)

Example:

```bash
SOURCES_FILE="$HOME/.config/streamlink_bgm_sources" \
SENDER="$HOME/bin/mpv_ipc_send" \
./bgm_tray.sh
```

## Troubleshooting track info updates

The OBS track title updates come from the watcher process (`streamlink_3.sh watch`, started automatically by `start`). If OBS stops updating, confirm the watcher is running and restart if needed:

```bash
pgrep -f "streamlink_3.sh watch" || ./streamlink_3.sh restart
```

If your MPV IPC is sluggish, the watcher retries before reconnecting. You can tune the polling timeout (seconds) and retry limit with environment variables:

```bash
MPV_IPC_TIMEOUT=3 WATCH_RETRY_LIMIT=8 ./streamlink_3.sh restart
```

## YouTube cookies (optional but recommended)

Some YouTube streams require authenticated cookies. The MPV launch in `streamlink_3.sh` always points to
`$HOME/cookies.txt`, so the easiest path is to generate that file once and keep it updated when your login changes.

**Fastest option (browser extension):**

1. Install a cookies exporter extension for your browser (e.g., “Get cookies.txt” or “cookies.txt”).
2. Sign in to YouTube in that browser.
3. Export cookies in Netscape format to `~/cookies.txt`.
4. If you refresh your login, re-export and overwrite `~/cookies.txt`.

**CLI option (yt-dlp):**

If you already use `yt-dlp`, you can export cookies from a browser profile:

```bash
yt-dlp --cookies-from-browser firefox --cookies "$HOME/cookies.txt" --skip-download "https://www.youtube.com/"
```

Replace `firefox` with `chromium`, `chrome`, or another supported browser if needed.

## Attribution

See `ATTRIBUTION.md`.
