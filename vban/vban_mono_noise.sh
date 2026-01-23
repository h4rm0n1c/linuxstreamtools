#!/bin/sh
# Graph:
#   vban_receptor --(pulseaudio)--> CleanBus:playback_MONO
#   CleanBus:monitor_MONO -> RNNOISEMONO -> MicBus:playback_MONO
#   MicBus:monitor_MONO -> VBAN_Mic (remap-source)

SCREEN_NAME=vban_mic
VBAN_SOURCE_NAME=rawmic
VBAN_HOST=10.0.42.249
VBAN_PORT=6980

# Ingest bus (VBAN goes here)
INGEST_SINK_NAME=CleanBus
INGEST_SINK_DESC="CleanBus"

# Mic bus (filter output goes here)
MIC_SINK_NAME=MicBus
MIC_SINK_DESC="MicBus"

# Virtual mic presented to apps
SOURCE_NAME=VBAN_Mic
SOURCE_DESC="VBANMic"

ensure_pipewire_ready() {
  i=0
  while [ $i -lt 5 ]; do
    if pw-cli ls Core >/dev/null 2>&1; then return 0; fi
    sleep 1
    i=$((i+1))
  done
  echo "Warning: PipeWire may not be ready yet." >&2
}

ensure_virtual_devices() {
  # Create CleanBus (mono, 48k)
  if ! pactl list short sinks | awk '{print $2}' | grep -qx "$INGEST_SINK_NAME"; then
    pactl load-module module-null-sink \
      sink_name="$INGEST_SINK_NAME" \
      sink_properties="device.description=$INGEST_SINK_DESC" \
      rate=48000 channels=1 >/dev/null
  fi

  # Create MicBus (mono, 48k)
  if ! pactl list short sinks | awk '{print $2}' | grep -qx "$MIC_SINK_NAME"; then
    pactl load-module module-null-sink \
      sink_name="$MIC_SINK_NAME" \
      sink_properties="device.description=$MIC_SINK_DESC" \
      rate=48000 channels=1 >/dev/null
  fi

  # (Re)create VBAN_Mic remap to MicBus.monitor
  MID="$(pactl list short modules | awk '/module-remap-source/ && /'"$SOURCE_NAME"'/ {print $1}')"
  [ -n "${MID:-}" ] && pactl unload-module "$MID" >/dev/null 2>&1 || true
  if ! pactl list short sources | awk '{print $2}' | grep -qx "$SOURCE_NAME"; then
    pactl load-module module-remap-source \
      master="${MIC_SINK_NAME}.monitor" \
      source_name="$SOURCE_NAME" \
      source_properties="device.description=$SOURCE_DESC" \
      rate=48000 channels=1 >/dev/null
  fi
}

# Resolve sink ports from object.path (works even if unlinked)
_get_playback_port() {
  pw-cli ls Port 2>/dev/null \
  | sed -n 's/.*object.path = "\([^"]*\)".*/\1/p' \
  | awk -v n="$1" -v d="$2" '
      $0 == n":playback_MONO" || $0 == d":playback_MONO" { print; exit }
      $0 == n":playback_0"    || $0 == d":playback_0"    { print; exit }
      $0 == n":playback_FL"   || $0 == d":playback_FL"   { print; exit }
    '
}
_get_monitor_port() {
  pw-cli ls Port 2>/dev/null \
  | sed -n 's/.*object.path = "\([^"]*\)".*/\1/p' \
  | awk -v n="$1" -v d="$2" '
      $0 == n":monitor_MONO" || $0 == d":monitor_MONO" { print; exit }
      $0 == n":monitor_0"    || $0 == d":monitor_0"    { print; exit }
      $0 == n":monitor_FL"   || $0 == d":monitor_FL"   { print; exit }
    '
}

# RNNoise filter ports (handle both naming styles)
resolve_rnnoise() {
  IN=$(pw-cli ls Port | sed -n 's/.*object.path = "\(input\.RNNOISEMONO:input_0\)".*/\1/p' | head -n1)
  OUT=$(pw-cli ls Port | sed -n 's/.*object.path = "\(output\.RNNOISEMONO:output_0\)".*/\1/p' | head -n1)

  if [ -n "$IN" ] && [ -n "$OUT" ]; then
    printf '%s %s\n' "$IN" "$OUT"
    return 0
  else
    echo "resolve_rnnoise: could not resolve input/output ports" >&2
    return 1
  fi
}


cleanup_spurious_links() {
  # Pairwise unlink in POSIX sh (no tuple-for)
  set -- \
    "null_mic:capture_FL" "input.RNNOISEMONO:input_FL" \
    "null_mic:capture_FR" "input.RNNOISEMONO:input_FR" \
    "output.RNNOISEMONO:output_FL" "null_sink:playback_FL" \
    "output.RNNOISEMONO:output_FR" "null_sink:playback_FR"
  while [ $# -gt 0 ]; do
    pw-link -d "$1" "$2" 2>/dev/null || true
    shift 2
  done
}

wire_chain() {
  IN_PLAY="$(_get_playback_port "$INGEST_SINK_NAME" "$INGEST_SINK_DESC")"
  IN_MON="$(_get_monitor_port  "$INGEST_SINK_NAME" "$INGEST_SINK_DESC")"
  MIC_PLAY="$(_get_playback_port "$MIC_SINK_NAME" "$MIC_SINK_DESC")"
  [ -n "$IN_PLAY" ] || { echo "Error: ${INGEST_SINK_NAME} playback port not found." >&2; return 1; }
  [ -n "$IN_MON"  ] || { echo "Error: ${INGEST_SINK_NAME} monitor port not found."  >&2; return 1; }
  [ -n "$MIC_PLAY" ] || { echo "Error: ${MIC_SINK_NAME} playback port not found."   >&2; return 1; }

  set -- $(resolve_rnnoise || true); RN_IN="${1:-}"; RN_OUT="${2:-}"
  [ -n "$RN_IN" ] && [ -n "$RN_OUT" ] || { echo "Error: RNNOISEMONO ports not found." >&2; return 1; }

  # CleanBus.monitor -> RNNoise (mono)
  pw-link "$IN_MON" "$RN_IN" 2>/dev/null || true
  # RNNoise -> MicBus.playback
  pw-link "$RN_OUT" "$MIC_PLAY" 2>/dev/null || true

  cleanup_spurious_links
}

seat_vban_pulse() {
  # Try up to ~20s to catch the Pulse stream from vban_receptor, then move it to CleanBus
  for _ in $(seq 1 80); do
    ID="$(
      pactl list sink-inputs | awk '
        /^[[:space:]]*Sink Input #/ { cur=$0; sub(/^.*#/, "", cur); sub(/[^0-9].*$/, "", cur) }
        /application.process.binary = "vban_receptor"/ { print cur; exit }
        /application.name = "VBAN RX"/                 { print cur; exit }
        /application.name = "vban_receptor"/           { print cur; exit }
      '
    )"
    [ -n "${ID:-}" ] && { pactl move-sink-input "$ID" "$INGEST_SINK_NAME" >/dev/null 2>&1 || true; break; }
    sleep 0.25
  done
}

ensure_chain_once() {
  # Make sure VBAN stream is seated on CleanBus
  seat_vban_pulse

  # Reassert filter links
  IN_MON="$(_get_monitor_port "$INGEST_SINK_NAME" "$INGEST_SINK_DESC")"
  MIC_PLAY="$(_get_playback_port "$MIC_SINK_NAME" "$MIC_SINK_DESC")"
  set -- $(resolve_rnnoise || true); RN_IN="${1:-}"; RN_OUT="${2:-}"
  [ -n "$IN_MON" ] && [ -n "$MIC_PLAY" ] && [ -n "$RN_IN" ] && [ -n "$RN_OUT" ] || return 0

  pw-link "$IN_MON" "$RN_IN" 2>/dev/null || true
  pw-link "$RN_OUT" "$MIC_PLAY" 2>/dev/null || true
  cleanup_spurious_links
}

auto_rewire_bg() {
  i=0
  while [ $i -lt 120 ]; do   # ~60s
    ensure_chain_once
    sleep 0.5
    i=$((i+1))
  done
}

start() {
  echo "Starting VBAN audio service (Pulse → CleanBus)…"
  screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true

  ensure_pipewire_ready
  ensure_virtual_devices

  echo "Launching vban_receptor…"
  # Route to CleanBus via Pulse; -d sets the stream name (not the sink)
  screen -dmS "$SCREEN_NAME" \
    env PULSE_SINK="$INGEST_SINK_NAME" \
    vban_receptor -i "$VBAN_HOST" -p "$VBAN_PORT" -s "$VBAN_SOURCE_NAME" \
      -b pulseaudio -d "VBAN RX" --channels=1

  sleep 5

  # Seat on CleanBus (if PULSE_SINK was ignored) and wire the chain
  seat_vban_pulse
  wire_chain
  ( auto_rewire_bg ) &

  echo "VBAN service started."
  echo "→ Mic available to apps as: $SOURCE_DESC ($SOURCE_NAME)"
}

stop() {
  echo "Stopping VBAN audio service…"
  screen -S "$SCREEN_NAME" -X quit 2>/dev/null || true
  echo "VBAN receiver stopped. (Buses and mic left in place.)"
}

purge() {
  echo "Stopping and removing virtual devices…"
  stop
  # unload VBAN_Mic and both sinks
  pactl list short modules | awk '
    /module-remap-source/ && /'"$SOURCE_NAME"'/ {print $1}
    /module-null-sink/ && /'"$INGEST_SINK_NAME"'/ {print $1}
    /module-null-sink/ && /'"$MIC_SINK_NAME"'/   {print $1}
  ' | while read -r MID; do pactl unload-module "$MID" >/dev/null 2>&1 || true; done
  echo "Purged buses and virtual mic."
}

status() {
  printf "%-50s" "VBAN receptor (screen):"
  if screen -list 2>/dev/null | grep -q "[.]$SCREEN_NAME"; then echo "Running"; else echo "Not running"; fi

  pactl list short sinks   | awk '{print $2}' | grep -qx "$INGEST_SINK_NAME" && echo "Ingest sink: $INGEST_SINK_NAME present" || echo "Ingest sink: $INGEST_SINK_NAME missing"
  pactl list short sinks   | awk '{print $2}' | grep -qx "$MIC_SINK_NAME"    && echo "Mic sink:    $MIC_SINK_NAME present"    || echo "Mic sink:    $MIC_SINK_NAME missing"
  pactl list short sources | awk '{print $2}' | grep -qx "$SOURCE_NAME"      && echo "Source:      $SOURCE_NAME present"      || echo "Source:      $SOURCE_NAME missing"

  echo "-- Key links --"
  pw-link -l | awk '
    function show(){print; getline; if($1=="|->"||$1=="|<-") print}
    /^CleanBus:(playback|monitor)_(MONO|0|FL)$/         {show(); next}
    /^MicBus:(playback|monitor)_(MONO|0|FL)$/           {show(); next}
    /^(input\.RNNOISEMONO:input_FL|RNNOISEMONO:input_0)$/   {show(); next}
    /^(output\.RNNOISEMONO:output_FL|RNNOISEMONO:output_0)$/ {show(); next}
    /^input\.VBAN_Mic:input_MONO$/                      {show(); next}
  '
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; sleep 1; start ;;
  status)  status ;;
  purge)   purge ;;
  *) echo "Usage: $0 {start|stop|restart|status|purge}" ;;
esac
