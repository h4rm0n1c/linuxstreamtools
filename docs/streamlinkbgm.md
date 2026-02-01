# Streamlink BGM setup guide

This guide covers installing and running the Streamlink BGM tools (`streamlink_3.sh` and `bgm_tray.sh`).

## Install prerequisites (Debian/Devuan)

```bash
sudo apt update
sudo apt install mpv streamlink screen jq socat pipewire-pulse yad
```

If you are using PulseAudio instead of PipeWire, install `pulseaudio` instead of `pipewire-pulse`.

## File layout

- `streamlinkbgm/streamlink_3.sh` — core controller for MPV + Streamlink.
- `streamlinkbgm/bgm_tray.sh` — optional YAD tray menu.
- `streamlinkbgm/streamlink_bgm_sources` — example sources list.

## Configuration paths

Both scripts read configuration from the XDG config directory:

- `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_url`
- `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_sources`
- `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_mode`
- `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_listen_sink`

Set `XDG_CONFIG_HOME` if you want to keep BGM config elsewhere:

```bash
export XDG_CONFIG_HOME="$HOME/.config"
```

## Quick start

From inside `streamlinkbgm/`:

```bash
./streamlink_3.sh start
```

Add sources (one URL per line) in `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_sources` and restart if needed:

```bash
./streamlink_3.sh restart
```

## Tray controller

The tray menu is optional and provides quick access to playback controls and URL management.

```bash
./bgm_tray.sh
```

### Tray overrides

You can override paths used by the tray menu:

- `SENDER` — path to `mpv_ipc_send` (defaults to `~/.local/bin/mpv_ipc_send`)
- `BGM_CTL` — path to `streamlink_3.sh`
- `SOURCES_FILE` — path to the sources list
- `IPC_PATH` — path to the MPV IPC socket (defaults to `/tmp/mpv_bgm.sock`)

Example:

```bash
SENDER="$HOME/bin/mpv_ipc_send" \
BGM_CTL="$HOME/bin/streamlink_3.sh" \
SOURCES_FILE="$HOME/.config/streamlink_bgm_sources" \
IPC_PATH="/tmp/mpv_bgm.sock" \
./bgm_tray.sh
```

### Tray icon status

The tray icon updates based on MPV state:

- Playing: `media-playback-start`
- Paused: `media-playback-pause` (requires `socat` + `jq`)
- Stopped / MPV not running: `media-playback-stop`

## Common commands

```bash
./streamlink_3.sh seturl "https://www.youtube.com/watch?v=..."
./streamlink_3.sh addurl "https://www.youtube.com/playlist?list=..."
./streamlink_3.sh listsources
./streamlink_3.sh setmode daily
./streamlink_3.sh next
./streamlink_3.sh shuffle
```

## Troubleshooting

- If the BGM list is empty, confirm `${XDG_CONFIG_HOME:-$HOME/.config}/streamlink_bgm_sources` has at least one non-comment line.
- If the tray menu can’t find `mpv_ipc_send`, set `SENDER` before launching `bgm_tray.sh`.
- For stubborn MPV IPC connections, restart the controller:

```bash
./streamlink_3.sh restart
```
