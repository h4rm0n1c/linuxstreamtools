#!/bin/bash
set -euo pipefail

# === Config ===
SINK_NAME="SET_MPV_TO_THIS"
SOURCE_NAME="Streamlink_BGM"
SCREEN_NAME="streamlink_bgm"
SCRIPT_NAME="$(basename "$0")"
WATCH_PATTERN="${SCRIPT_NAME} watch"

CONFIG_DIR="${HOME}/.config"
CONFIG_URL_FILE="${CONFIG_DIR}/streamlink_bgm_url"
SOURCES_FILE="${CONFIG_DIR}/streamlink_bgm_sources"
MODE_FILE="${CONFIG_DIR}/streamlink_bgm_mode"
DEFAULT_URL="https://www.youtube.com/watch?v=jfKfPfyJRdk"

# Local listening (secondary output)
LISTEN_SINK_FILE="${CONFIG_DIR}/streamlink_bgm_listen_sink"
LISTEN_MODULE_ID_FILE="${CONFIG_DIR}/streamlink_bgm_listen_module_id"

IPC="/tmp/mpv_bgm.sock"
MEME_SOCK="/tmp/obs_meme_daemon.sock"
MPV_IPC_TIMEOUT="${MPV_IPC_TIMEOUT:-2}"
WATCH_RETRY_LIMIT="${WATCH_RETRY_LIMIT:-5}"

mkdir -p "${CONFIG_DIR}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need pactl
need screen
need mpv
need jq
need socat

wait_for_sink() {
  for _ in {1..50}; do
    pactl list short sinks | awk -v n="$SINK_NAME" '$2==n{found=1} END{exit !found}' && return 0
    sleep 0.1
  done
  return 1
}

# === Local listening helpers ===
get_default_sink() {
  pactl get-default-sink 2>/dev/null || pactl info | awk -F': ' '/Default Sink:/{print $2}'
}

list_sinks() {
  pactl list short sinks | awk '{printf "%2d) %s\t%s\n", NR, $2, $NF}'
}

sink_exists() {
  local s="$1"
  pactl list short sinks | awk -v n="$s" '$2==n{found=1} END{exit !found}'
}

resolve_sink_arg() {
  local arg="${1-}"
  if [ -z "$arg" ] || [ "$arg" = "default" ]; then
    get_default_sink
    return 0
  fi

  if printf '%s' "$arg" | grep -Eq '^[0-9]+$'; then
    # Nth sink from list
    pactl list short sinks | awk -v n="$arg" 'NR==n{print $2; exit}'
    return 0
  fi

  printf '%s\n' "$arg"
}

listen_stop_now() {
  if [ -f "$LISTEN_MODULE_ID_FILE" ]; then
    local id
    id="$(cat "$LISTEN_MODULE_ID_FILE" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      pactl unload-module "$id" >/dev/null 2>&1 || true
    fi
    rm -f "$LISTEN_MODULE_ID_FILE"
  fi
}

listen_apply_now() {
  # Requires: $SINK_NAME exists (null sink loaded)
  local target="$1"

  if ! sink_exists "$SINK_NAME"; then
    echo "WARN: null sink '$SINK_NAME' not present yet; can't enable listen."
    return 1
  fi

  if ! sink_exists "$target"; then
    echo "ERROR: target sink '$target' not found."
    echo "Tip: run '$0 sinks' and pick a sink name or number."
    return 1
  fi

  listen_stop_now

  # Loopback: null sink monitor -> chosen sink
  # Keep latency modest; tweak if you care (40-100ms typical).
  local id=""
  id="$(pactl load-module module-loopback \
    source="${SINK_NAME}.monitor" \
    sink="$target" \
    latency_msec=60 \
    sink_input_properties="media.name=Streamlink_BGM_listen" \
    source_output_properties="media.name=Streamlink_BGM_listen" \
    2>/dev/null || true)"

  if [ -z "$id" ]; then
    echo "WARN: failed to load module-loopback (is pipewire-pulse/pulse loopback available?)."
    return 1
  fi

  echo "$id" > "$LISTEN_MODULE_ID_FILE"
  echo "[LISTEN] enabled: ${SINK_NAME}.monitor -> $target (module $id)"
  return 0
}

listen_maybe_start() {
  # If user configured a listen sink previously, enable it on start.
  [ -f "$LISTEN_SINK_FILE" ] || return 0
  local target
  target="$(sed -n '1p' "$LISTEN_SINK_FILE" 2>/dev/null || true)"
  [ -n "$target" ] || return 0
  listen_apply_now "$target" || true
}

# === Pick source ===
pick_source() {
  if [ -f "$SOURCES_FILE" ] && \
     grep -v '^\s*#' "$SOURCES_FILE" | grep -q '[^[:space:]]'; then
    mapfile -t POOL < <(grep -v '^\s*#' "$SOURCES_FILE" | sed '/^\s*$/d')
    local n=${#POOL[@]}
    if [ "$n" -gt 0 ]; then
      local mode="random"
      [ -f "$MODE_FILE" ] && mode="$(tr '[:upper:]' '[:lower:]' < "$MODE_FILE")"
      if [ "$mode" = "daily" ]; then
        local day seed idx
        day="$(date +%Y-%m-%d)"
        seed=$(printf '%s\n' "$day" | cksum | awk '{print $1}')
        idx=$(( seed % n ))
        echo "${POOL[$idx]}"
      else
        idx=$(( RANDOM % n ))
        echo "${POOL[$idx]}"
      fi
      return
    fi
  fi

  if [ -f "$CONFIG_URL_FILE" ]; then
    sed -n '1p' "$CONFIG_URL_FILE"
  else
    echo "$DEFAULT_URL"
  fi
}

# === MPV IPC helpers ===
mpv_send() {
  local cmd="$1"
  [ -S "$IPC" ] || return 1
  printf '%s\n' "$cmd" | socat - UNIX-CONNECT:"$IPC" >/dev/null 2>&1 || true
}

announce_track() {
  local title="$1"
  if [ -S "$MEME_SOCK" ]; then
    printf "TRACK Music: %s\n" "$title" | socat - UNIX-CONNECT:"$MEME_SOCK" >/dev/null 2>&1 || true
  fi
}

announce_clear() {
  if [ -S "$MEME_SOCK" ]; then
    printf "TRACK_CLEAR\n" | socat - UNIX-CONNECT:"$MEME_SOCK" >/dev/null 2>&1 || true
  fi
}

# === Track watcher ===
mpv_query_title() {
  local ipc="$1"
  local resp=""

  if command -v timeout >/dev/null 2>&1; then
    resp=$(printf '{"command":["get_property","media-title"]}\n' \
      | timeout "${MPV_IPC_TIMEOUT}s" socat - UNIX-CONNECT:"$ipc" 2>/dev/null || true)
  else
    resp=$(printf '{"command":["get_property","media-title"]}\n' \
      | socat - UNIX-CONNECT:"$ipc" 2>/dev/null || true)
  fi

  printf '%s\n' "$resp" \
    | jq -r 'select(.error=="success") | .data // empty' 2>/dev/null \
    | head -n1
}

mpv_track_watcher() {
  local ipc="$IPC"
  local last=""
  local failures=0

  while true; do
    while [ ! -S "$ipc" ]; do
      sleep 0.5
    done

    echo "[TRACK] watcher attached to $ipc"

    while [ -S "$ipc" ]; do
      title="$(mpv_query_title "$ipc")"

      if [ -n "$title" ]; then
        failures=0
        if [ "$title" != "$last" ]; then
          echo "[TRACK] Now playing: $title"
          announce_track "$title"
          last="$title"
        fi
      else
        failures=$((failures + 1))
        if [ "$failures" -ge "$WATCH_RETRY_LIMIT" ]; then
          echo "[TRACK] no IPC response after ${failures} polls; reconnecting"
          break
        fi
      fi

      sleep 2
    done

    announce_clear
    last=""
    failures=0
  done
}

start_watcher() {
  if pgrep -f "$WATCH_PATTERN" >/dev/null 2>&1; then
    return
  fi
  "$0" watch &
}

# === Actions ===
start() {
  echo "Creating PipeWire null sink for MPV output..."
  pactl list short modules \
    | awk -v pat="$SINK_NAME" 'index($0, pat){print $1}' \
    | while read -r id; do pactl unload-module "$id" >/dev/null 2>&1 || true; done

  pactl load-module module-null-sink \
    sink_name="$SINK_NAME" \
    sink_properties=device.description="$SINK_NAME" >/dev/null

  wait_for_sink || echo "WARN: $SINK_NAME not visible yet"

  echo "Creating remapped source for OBS..."
  pactl list short modules \
    | awk -v pat="$SOURCE_NAME" 'index($0, pat){print $1}' \
    | while read -r id; do pactl unload-module "$id" >/dev/null 2>&1 || true; done

  pactl load-module module-remap-source \
    master="$SINK_NAME.monitor" \
    source_name="$SOURCE_NAME" \
    source_properties=device.description="$SOURCE_NAME" >/dev/null

  pactl set-sink-volume "$SINK_NAME" 80% || true

  # Start local listening if configured
  listen_maybe_start

  start_mpv
  start_watcher
}

start_mpv() {
  local PICKED
  PICKED="$(pick_source)"
  echo "Starting MPV from source: $PICKED"

  (screen -ls 2>/dev/null || true) | awk -v name="$SCREEN_NAME" '
    $0 ~ "\\."name"[[:space:]]" { print $1 }
  ' | while read -r sid; do
    echo "  killing stale screen session $sid"
    screen -S "$sid" -X quit || true
  done

  [ -S "$IPC" ] && rm -f "$IPC"

  screen -S "$SCREEN_NAME" -dm bash -c '
    URL="$1"
    SINK="pipewire/'"$SINK_NAME"'"
    IPC="'"$IPC"'"

    while true; do
      echo "[MPV] Starting ($URL)"
      mpv \
        --no-video \
        --ao=pipewire \
        --audio-device="$SINK" \
        --audio-samplerate=48000 \
        --loop-file=no \
        --shuffle \
        --input-ipc-server="$IPC" \
        --ytdl-raw-options=compat-options=no-connection-reuse \
        --ytdl-raw-options=yes-playlist=,cookies=$HOME/cookies.txt \
        "$URL"

      echo "[MPV] Exited. Retrying in 10s..."
      sleep 10
    done
  ' _ "$PICKED"
}

start_mpv_with_url() {
  local FIXED_URL="${1-}"
  [ -n "$FIXED_URL" ] || { echo "start_mpv_with_url: missing URL"; exit 1; }

  [ -S "$IPC" ] && rm -f "$IPC"

  screen -S "$SCREEN_NAME" -dm bash -c '
    URL="$1"
    SINK="pipewire/'"$SINK_NAME"'"
    IPC="'"$IPC"'"

    while true; do
      echo "[MPV] Starting ($URL)"
      mpv \
        --no-video \
        --ao=pipewire \
        --audio-device="$SINK" \
        --audio-samplerate=48000 \
        --loop-file=no \
        --shuffle \
        --input-ipc-server="$IPC" \
        --ytdl-raw-options=compat-options=no-connection-reuse \
        --ytdl-raw-options=yes-playlist=,cookies=$HOME/cookies.txt \
        "$URL"

      echo "[MPV] Exited. Retrying in 10s..."
      sleep 10
    done
  ' _ "$FIXED_URL"
}

stop_mpv() {
  echo "Stopping MPV…"

  (screen -ls 2>/dev/null || true) | awk -v name="$SCREEN_NAME" '
    $0 ~ "\\."name"[[:space:]]" { print $1 }
  ' | while read -r sid; do
    echo "  killing screen session $sid"
    screen -S "$sid" -X quit || true
  done

  [ -S "$IPC" ] && rm -f "$IPC"
  announce_clear

  pkill -f "$WATCH_PATTERN" 2>/dev/null || true
}

stop() {
  stop_mpv
  listen_stop_now
  echo "Unloading modules…"
  pactl list short modules | awk -v pat="$SOURCE_NAME" 'index($0, pat){print $1}' | while read -r id; do pactl unload-module "$id" >/dev/null 2>&1 || true; done
  pactl list short modules | awk -v pat="$SINK_NAME" 'index($0, pat){print $1}' | while read -r id; do pactl unload-module "$id" >/dev/null 2>&1 || true; done
}

restart() { stop; sleep 1; start; }

restart_mpv_only() {
  stop_mpv
  sleep 0.5
  start_mpv
  start_watcher
}

status() {
  if screen -list | grep -q "$SCREEN_NAME"; then
    echo "MPV BGM is running."
  else
    echo "MPV BGM not running."
  fi

  if [ -f "$LISTEN_MODULE_ID_FILE" ]; then
    local id
    id="$(cat "$LISTEN_MODULE_ID_FILE" 2>/dev/null || true)"
    if [ -n "$id" ]; then
      echo "Local listen: enabled (module $id)"
    else
      echo "Local listen: enabled (module unknown)"
    fi
  elif [ -f "$LISTEN_SINK_FILE" ]; then
    echo "Local listen: configured but not active (start to enable)"
  else
    echo "Local listen: disabled"
  fi
}

seturl() {
  local new_url="${1-}"
  [ -n "$new_url" ] || { echo "Usage: $0 seturl <URL>"; exit 1; }

  echo "$new_url" > "$CONFIG_URL_FILE"
  touch "$SOURCES_FILE"

  if ! grep -Fxq "$new_url" "$SOURCES_FILE"; then
    echo "$new_url" >> "$SOURCES_FILE"
  fi

  stop_mpv
  sleep 0.5
  start_mpv_with_url "$new_url"
  start_watcher
}

addurl() {
  local new="${1-}"
  [ -n "$new" ] || { echo "Usage: $0 addurl <URL>"; exit 1; }

  touch "$SOURCES_FILE"
  if ! grep -Fxq "$new" "$SOURCES_FILE"; then
    echo "$new" >> "$SOURCES_FILE"
  fi
  restart_mpv_only
}

delurl() {
  [ -f "$SOURCES_FILE" ] || { echo "No sources file"; return; }
  local del="${1-}"
  grep -Fxv "$del" "$SOURCES_FILE" > "$SOURCES_FILE.tmp" || true
  mv "$SOURCES_FILE.tmp" "$SOURCES_FILE"
  restart_mpv_only
}

cleandupes() {
  [ -f "$SOURCES_FILE" ] || return
  awk '!seen[$0]++' "$SOURCES_FILE" > "$SOURCES_FILE.tmp"
  mv "$SOURCES_FILE.tmp" "$SOURCES_FILE"
}

listsources() { [ -f "$SOURCES_FILE" ] && nl -ba "$SOURCES_FILE" || echo "(none)"; }

setmode() {
  local m="${1-}"
  echo "$m" > "$MODE_FILE"
  restart_mpv_only
}

# Local listen commands
listen() {
  local arg="${1-}"
  local target
  target="$(resolve_sink_arg "$arg")"
  [ -n "$target" ] || { echo "ERROR: couldn't resolve target sink"; exit 1; }

  echo "$target" > "$LISTEN_SINK_FILE"

  # If the null sink exists, apply now; otherwise it'll apply on next start.
  if sink_exists "$SINK_NAME"; then
    listen_apply_now "$target"
  else
    echo "[LISTEN] configured: will enable on next start -> $target"
  fi
}

unlisten() {
  rm -f "$LISTEN_SINK_FILE"
  listen_stop_now
  echo "[LISTEN] disabled"
}

next_track() { mpv_send '{"command":["playlist-next"]}'; }
prev_track() { mpv_send '{"command":["playlist-prev"]}'; }
shuffle_now() { mpv_send '{"command":["playlist-shuffle"]}'; }
pause_play() { mpv_send '{"command":["cycle","pause"]}'; }
pause_only() { mpv_send '{"command":["set","pause",true]}'; }
resume_only() { mpv_send '{"command":["set","pause",false]}'; }
vol() {
  local d="${1-}"
  mpv_send '{"command":["add","volume",'$d']}'
}
what() {
  mpv_send '{"command":["get_property","media-title"]}'
  mpv_send '{"command":["get_property","path"]}'
}

case "${1-}" in
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  seturl) shift; seturl "${1-}" ;;
  addurl) shift; addurl "${1-}" ;;
  delurl) shift; delurl "${1-}" ;;
  listsources) listsources ;;
  setmode) shift; setmode "${1-}" ;;
  cleandupes) cleandupes ;;
  next) next_track ;;
  prev) prev_track ;;
  shuffle) shuffle_now ;;
  pause) pause_only ;;
  resume) resume_only ;;
  toggle) pause_play ;;
  watch) mpv_track_watcher ;;
  vol) shift; vol "${1-}" ;;
  what) what ;;
  sinks) list_sinks ;;
  listen) shift; listen "${1-}" ;;
  unlisten) unlisten ;;
  *) echo "Usage: $0 {start|stop|restart|status|seturl|addurl|delurl|listsources|setmode|cleandupes|next|prev|shuffle|pause|resume|toggle|vol|what|sinks|listen [sink|N]|unlisten}"; exit 1 ;;
esac
