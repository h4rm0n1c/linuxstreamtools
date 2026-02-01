#!/bin/bash
set -euo pipefail

# Detach from terminal so backgrounding won't "stop" the job
exec </dev/null

YAD="$(command -v yad)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
SENDER="${SENDER:-$HOME/.local/bin/mpv_ipc_send}"
BGM_CTL="${BGM_CTL:-$SCRIPT_DIR/streamlink_3.sh}"   # <-- point this at streamlink_3.sh
SOURCES_FILE="${SOURCES_FILE:-$CONFIG_DIR/streamlink_bgm_sources}"

[ -x "$YAD" ] || { echo "yad not found"; exit 1; }
[ -x "$SENDER" ] || { echo "mpv_ipc_send missing"; exit 1; }
[ -x "$BGM_CTL" ] || { echo "BGM controller script not found: $BGM_CTL"; exit 1; }

# Export so bash -lc from the menu can see it
export BGM_CTL
export SOURCES_FILE

choose_bgm_url() {
  if [ ! -f "$SOURCES_FILE" ]; then
    yad --info --title="Choose BGM URL" --text="No sources file found: $SOURCES_FILE"
    return 0
  fi

  if ! awk "NF && \$1 !~ /^#/" "$SOURCES_FILE" | grep -q .; then
    yad --info --title="Choose BGM URL" --text="No saved URLs found in: $SOURCES_FILE"
    return 0
  fi

  URL="$(
    awk "NF && \$1 !~ /^#/" "$SOURCES_FILE" | yad --list --column="URL" --no-markup --no-headers --print-column=1 --separator="" --width=900 --height=400 --title="Choose BGM URL" --center
  )"
  if [ -n "$URL" ]; then
    "$BGM_CTL" seturl "$URL"
  else
    yad --info --title="Choose BGM URL" --text="No selection made."
  fi
}

export -f choose_bgm_url

set_bgm_url() {
  URL="$(yad --entry --width=700 --title="Set BGM URL" --text="Enter YouTube or playlist URL:")"
  if [ -n "$URL" ]; then
    "$BGM_CTL" seturl "$URL"
  fi
}

delete_bgm_url() {
  URL="$(yad --entry --width=700 --title="Delete BGM URL" --text="Enter URL to remove (exact match in sources file):")"
  if [ -n "$URL" ]; then
    "$BGM_CTL" delurl "$URL"
  fi
}

clean_bgm_urls() {
  "$BGM_CTL" cleandupes
}

edit_bgm_url_list() {
  if command -v xfce4-terminal >/dev/null 2>&1; then
    xfce4-terminal --maximize --title="BGM URLs" --command="nano ~/.config/streamlink_bgm_sources"
  else
    x-terminal-emulator -e nano ~/.config/streamlink_bgm_sources
  fi
}

export -f set_bgm_url
export -f delete_bgm_url
export -f clean_bgm_urls
export -f edit_bgm_url_list

# Right-click menu: use absolute commands; '---' makes separators in yad
#MENU="Next Song!$SENDER next|Previous Song!$SENDER prev|Pause/Resume!$SENDER toggle|Shuffle!$SENDER shuffle|---|Seek +10s!$SENDER seekf|Seek -10s!$SENDER seekb|Volume +5!$SENDER volup|Volume -5!$SENDER voldn|---|Set BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Set BGM URL\" --text=\"Enter YouTube or playlist URL:\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" seturl \"\$URL\"'|Delete BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Delete BGM URL\" --text=\"Enter URL to remove (exact match in sources file):\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" delurl \"\$URL\"'|Clean duplicate URLs!bash -lc '\"$BGM_CTL\" cleandupes'|---|Open in Browser!$SENDER open|Quit Tray!bash -lc 'kill $$'"
# Right-click menu: use absolute commands; '---' makes separators in yad
#MENU="Next Song!$SENDER next|Previous Song!$SENDER prev|Pause/Resume!$SENDER toggle|Shuffle!$SENDER shuffle|---|Seek +10s!$SENDER seekf|Seek -10s!$SENDER seekb|Volume +5!$SENDER volup|Volume -5!$SENDER voldn|---|Set BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Set BGM URL\" --text=\"Enter YouTube or playlist URL:\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" seturl \"\$URL\"'|Delete BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Delete BGM URL\" --text=\"Enter URL to remove (exact match in sources file):\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" delurl \"\$URL\"'|Clean duplicate URLs!bash -lc '\"$BGM_CTL\" cleandupes'|Edit BGM URL list...!bash -lc 'x-terminal-emulator -e nano \"$HOME/.config/streamlink_bgm_sources\"'|---|Open in Browser!$SENDER open|Quit Tray!bash -lc 'kill $$'"
# Right-click menu: use absolute commands; '---' makes separators in yad
#MENU="Next Song!$SENDER next|Previous Song!$SENDER prev|Pause/Resume!$SENDER toggle|Shuffle!$SENDER shuffle|---|Seek +10s!$SENDER seekf|Seek -10s!$SENDER seekb|Volume +5!$SENDER volup|Volume -5!$SENDER voldn|---|Set BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Set BGM URL\" --text=\"Enter YouTube or playlist URL:\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" seturl \"\$URL\"'|Delete BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Delete BGM URL\" --text=\"Enter URL to remove (exact match in sources file):\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" delurl \"\$URL\"'|Clean duplicate URLs!bash -lc '\"$BGM_CTL\" cleandupes'|Edit BGM URL list...!bash -lc 'if command -v xfce4-terminal >/dev/null 2>&1; then xfce4-terminal --maximize --title=\"BGM URLs\" -e nano \"$HOME/.config/streamlink_bgm_sources\"; else x-terminal-emulator -e nano \"$HOME/.config/streamlink_bgm_sources\"; fi'|---|Open in Browser!$SENDER open|Quit Tray!bash -lc 'kill $$'"
#MENU="Next Song!$SENDER next|Previous Song!$SENDER prev|Pause/Resume!$SENDER toggle|Shuffle!$SENDER shuffle|---|Seek +10s!$SENDER seekf|Seek -10s!$SENDER seekb|Volume +5!$SENDER volup|Volume -5!$SENDER voldn|---|Set BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Set BGM URL\" --text=\"Enter YouTube or playlist URL:\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" seturl \"\$URL\"'|Delete BGM URL...!bash -lc 'URL=\$(yad --entry --width=700 --title=\"Delete BGM URL\" --text=\"Enter URL to remove (exact match in sources file):\"); [ -n \"\$URL\" ] && \"\$BGM_CTL\" delurl \"\$URL\"'|Clean duplicate URLs!bash -lc '\"$BGM_CTL\" cleandupes'|Edit BGM URL list...!bash -lc 'if command -v xfce4-terminal >/dev/null 2>&1; then xfce4-terminal --maximize --title=\"BGM URLs\" -- nano \"$HOME/.config/streamlink_bgm_sources\"; else x-terminal-emulator -e nano \"$HOME/.config/streamlink_bgm_sources\"; fi'|---|Open in Browser!$SENDER open|Quit Tray!bash -lc 'kill $$'"
MENU="Next Song!$SENDER next|Previous Song!$SENDER prev|Pause/Resume!$SENDER toggle|Shuffle!$SENDER shuffle|---|Seek +10s!$SENDER seekf|Seek -10s!$SENDER seekb|Volume +5!$SENDER volup|Volume -5!$SENDER voldn|---|Choose BGM URL...!bash -lc 'choose_bgm_url'|Set BGM URL...!bash -lc 'set_bgm_url'|Delete BGM URL...!bash -lc 'delete_bgm_url'|Clean duplicate URLs!bash -lc 'clean_bgm_urls'|Edit BGM URL list...!bash -lc 'edit_bgm_url_list'|---|Open in Browser!$SENDER open|Quit Tray!bash -lc 'kill $$'"



# Left-click toggles pause/resume directly via the sender
exec "$YAD" --notification \
  --image=media-playback-start \
  --text="BGM Controller" \
  --command="$SENDER toggle" \
  --menu="$MENU"
