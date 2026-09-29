#!/usr/bin/env bash
# ~/.config/swaync/actions.sh
# The "heavy" swaync actions (screenshot / screen recording), kept out of
# config.json.
#
# Usage: actions.sh <snip|shot|capture-open <area|screen|window> <photo|video>|shot-crop x y w h [cursor]|rec|rec-area|rec-start [geometry]|rec-stop|rec-discard|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>
#
# WHY A SEPARATE FILE:
#   1. Nobody can debug a multi-command pipeline stuffed into a JSON string:
#      swaync spawns it through GLib, and the child's stdout/stderr go nowhere. When
#      the command dies for any reason, all you see is "nothing happened".
#   2. This file writes ALL stdout+stderr+trace to the log. Press the button once,
#      then read the log to see exactly where it broke.
#   3. It runs standalone from a terminal for comparison:  ~/.config/swaync/actions.sh snip
#
# LOG:  ~/.cache/swaync-actions.log   (trimmed to the last 200 lines)

set -u

# ============================ VOLUME =========================================
# Handled BEFORE the logging block: volume keys get pressed a lot and should not flood the log.
#
# WHY NOT RELATIVE `+5%` / `-5%`:
#   The relative form adds the delta to EACH channel and rounds each one on its own. ALSA Master
#   on Intel HDA has only a few dozen integer steps (e.g. 0-87), so 5% = 4.35 steps -> front-left
#   and front-right round differently and drift apart. Once they drift, they never come back.
#   The ABSOLUTE form with no channel prefix (`pactl set-sink-volume SINK 65%`) applies
#   THE SAME value to EVERY channel, so the two sides cannot drift. Read the current
#   value -> add -> write it back as an absolute. That also clamps at 0 and 100.
#
# Checking for channel drift (run before and after pressing the keys a few times):
#     pactl get-sink-volume @DEFAULT_SINK@ | head -1
#   front-left != front-right = drifted. Rebalance right away:
#     pactl set-sink-volume @DEFAULT_SINK@ 100%
VOL_STEP="${VOL_STEP:-5}"

vol_cur() {
  pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
    | grep -o '[0-9]\+%' | head -1 | tr -d '%'
}

vol_step() {                       # $1 = integer delta, e.g. 5 or -5
  local c n
  c=$(vol_cur)
  [[ $c =~ ^[0-9]+$ ]] || exit 1   # unreadable -> stop, don't guess
  n=$(( c + $1 ))
  [[ $n -gt 100 ]] && n=100
  [[ $n -lt 0   ]] && n=0
  pactl set-sink-volume @DEFAULT_SINK@ "${n}%"
}

case "${1:-}" in
  vol-up)   vol_step  "$VOL_STEP"       ; exit 0 ;;
  vol-down) vol_step "-$VOL_STEP"       ; exit 0 ;;
  vol-mute) pactl set-sink-mute   @DEFAULT_SINK@   toggle >/dev/null; exit 0 ;;
  mic-mute) pactl set-source-mute @DEFAULT_SOURCE@ toggle >/dev/null; exit 0 ;;
esac
# =============================================================================

LOG="${XDG_CACHE_HOME:-$HOME/.cache}/swaync-actions.log"
mkdir -p "$(dirname "$LOG")"

# Rotate the log: keep the last 200 lines so the file never grows without bound.
if [[ -f $LOG ]]; then
  tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

# From here on EVERYTHING goes to the log.
# Note: the pipeline (grim | tee | wl-copy -t image/png) sets its own stdout, so it is unaffected.
exec >>"$LOG" 2>&1

echo "===== $(date '+%F %T')  argv=[$*]"
echo "      WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
echo "      XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<unset>}"
echo "      PATH=$PATH"
set -x

# xdg-user-dir returns $HOME when the matching variable is NOT in
# ~/.config/user-dirs.dirs -> files land straight in ~/Screenshots, ~/Recordings.
# Your log showed exactly that happening:  PIC=$HOME/Screenshots
# This function detects that case and falls back to the standard path.
xdg_dir() {                       # $1 = XDG name, $2 = fallback path
  local d
  d=$(xdg-user-dir "$1" 2>/dev/null)
  [[ -z $d || $d == "$HOME" || $d == "$HOME/" ]] && d="$HOME/$2"
  printf '%s' "$d"
}
PIC="$(xdg_dir PICTURES Pictures)/Screenshots"
VID="$(xdg_dir VIDEOS Videos)/Recordings"

# rofi theme. A bare `rofi -dmenu` does NOT use the theme your launcher sets —
# the launcher passes its own -theme, so that config does not apply here, and rofi falls
# back to its built-in theme (plain background, square corners — an unriced dmenu look).
# Point straight at the theme file. To use another of your themes, change this line.
ROFI_THEME="${ROFI_THEME:-$HOME/.config/rofi/config/clipboard.rasi}"

# notify-send must never kill the script when the daemon isn't ready yet
notify() { notify-send -a swaync "$1" "$2" || true; }

# Close the control centre before capturing or recording.
#
# A BUG THAT ONCE LIVED HERE: calling a bare `swaync-client -cp`.
# swaync-client WAITS BY DEFAULT for swaync to appear on D-Bus — there is a flag,
# `-sw/--skip-wait`, to NOT wait. So when swaync is not running (e.g. just killed for
# debugging, or autostart not there yet), that line HANGS FOREVER. `|| true` cannot
# help, because the command never returns. Result: snip/shot/rec-area died silently,
# the log stopped right at that line, and `cal` (which doesn't call swaync-client) still worked.
#
# Two layers of protection: -sw so it doesn't wait, and timeout for every other case.
close_panel() { timeout 1 swaync-client -cp -sw >/dev/null 2>&1 || true; }

# `pgrep -x` MATCHES ZOMBIES TOO: a process that has died but not been reaped by its parent
# still has an entry in /proc. Found while testing: a fake wf-recorder died immediately,
# pgrep still said "running" -> the script said "started" when it had failed.
# On Arch systemd is PID 1, so orphans are reaped at once, but filtering is still more correct.
rec_alive() {
  local p s
  for p in $(pgrep -x wf-recorder 2>/dev/null); do
    s=$(ps -o stat= -p "$p" 2>/dev/null)
    [[ $s == Z* ]] || return 0
  done
  return 1
}

# wf-recorder does NOT accept "-a DEVICE" (with a space). -a takes an OPTIONAL argument, so
# getopt only picks it up when attached: -a<DEVICE> or --audio=<DEVICE>.
# Evidence from your log: passing "-a alsa_output....monitor" made wf-recorder
# print "Using PulseAudio device: default" -> the string was ignored and it recorded the MIC.
#
# RECORDING INDICATOR
# No swaync widget at all — just an urgency=critical notification.
# config.json sets "timeout-critical": 0, so it STAYS on screen for the whole
# recording. On stop, `notify-send -r <id>` replaces it with a transient one.
# No state to drift, no rewriting config.json.
REC_ID="${XDG_RUNTIME_DIR:-/tmp}/swaync-rec-id"

# STATE FOR THE RECORDING ISLAND (docs/capture-ui.md §2.2)
# The island (Quickshell, ~/.config/quickshell/enhalation) only READS this file and never
# runs a recorder itself: this script is still the ONLY thing that runs wf-recorder. Written
# atomically (tmp + mv), so the island never reads a half-written file.
# When the island is NOT running (`ping` fails), the old notification is used instead —
# never both at once.
#
# WHO WRITES THE FINAL STATE: ONLY `rec-exited`. rec_start runs wf-recorder UNDER a
# supervising bash; when wf-recorder exits for any reason (Stop, discard, crash), that bash
# calls `actions.sh rec-exited <code>` — by then the file is finalized. So there is
# no path that leaves the island stuck on "REC".
REC_STATE="${XDG_RUNTIME_DIR:-/tmp}/capture/rec.json"
REC_DISCARD="${XDG_RUNTIME_DIR:-/tmp}/capture/discard"
REC_LOCK="${XDG_RUNTIME_DIR:-/tmp}/capture/rec.lock"
ACTIONS="$(realpath "${BASH_SOURCE[0]}")"

json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# rec_state <state> <file> <started ms> <mode> [geometry] [size] [duration_ms] [pid]
# pid is only for reading the log and debugging; nothing polls it.
rec_state() {
  local g=null s=null d=null p=null
  [[ -n ${5:-} ]] && g=$(json_str "$5")
  [[ -n ${6:-} ]] && s=$6
  [[ -n ${7:-} ]] && d=$7
  [[ -n ${8:-} ]] && p=$8
  mkdir -p "$(dirname "$REC_STATE")"
  printf '{"state":"%s","file":%s,"started":%s,"mode":"%s","geometry":%s,"audio":"desktop","size":%s,"duration_ms":%s,"pid":%s,"log":%s}\n' \
    "$1" "$(json_str "$2")" "$3" "$4" "$g" "$s" "$d" "$p" "$(json_str "$LOG")" >"$REC_STATE.tmp" \
    && mv -f "$REC_STATE.tmp" "$REC_STATE"
}

rec_field() {                      # $1 = key in rec.json; empty if absent
  python3 -c 'import json, sys
try: v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception: v = None
print("" if v is None else v)' "$REC_STATE" "$1" 2>/dev/null
}

# EVERY IPC call to Quickshell goes through here, so nobody forgets `--`: a function named
# like a `qs ipc` subcommand (e.g. "show") is misparsed by the CLI (exit 109). Rule: no
# IPC function may share a name with a `qs ipc` subcommand (docs/capture-ui.md §2.2).
qs_call() { timeout 2 qs -c enhalation ipc call -- "$@"; }
island_up() { qs_call rec ping >/dev/null 2>&1; }

# The old "REC" notification (if any): island running -> close it; otherwise -> replace it with $1/$2.
rec_note_done() {
  local id
  id=$(cat "$REC_ID" 2>/dev/null) || id=""
  if island_up; then
      [[ -n $id ]] && gdbus call --session --dest org.freedesktop.Notifications \
          --object-path /org/freedesktop/Notifications \
          --method org.freedesktop.Notifications.CloseNotification "$id" >/dev/null 2>&1
  elif [[ -n $id ]]; then
      notify-send -a swaync -r "$id" -t 4000 "$1" "$2" || true
  else
      notify "$1" "$2"
  fi
  rm -f "$REC_ID"
}

rec_start() {                      # $1 = geometry "x,y WxH" (empty = full screen)
  close_panel
  mkdir -p "$VID"
  local F MON args id started pid mode=screen
  F="$VID/$(date +%F_%H-%M-%S).mp4"
  MON="$(pactl get-default-sink).monitor"      # desktop audio, NOT the mic
  args=( -D -r 60 "--audio=$MON" -f "$F" )
  [[ -n ${1:-} ]] && { args+=( -g "$1" ); mode=area; }
  started=$(date +%s%3N)
  rm -f "$REC_DISCARD"
  # Write "recording" BEFORE starting: if wf-recorder dies at once, rec-exited reads the file
  # of THIS run (not a stale one left in rec.json) and writes "failed".
  rec_state recording "$F" "$started" "$mode" "${1:-}"
  # $0 = this script's path, "$@" = exactly the args above (keeps --audio=).
  # Call `bash "$0"`, not the script itself: the exec bit can get lost (see wayfire.ini).
  setsid -f bash -c 'wf-recorder "$@"; bash "$0" rec-exited $?' "$ACTIONS" "${args[@]}"
  sleep 0.8
  # `setsid -f` returns immediately, so its exit code does NOT tell whether
  # wf-recorder started. Check the real process.
  if rec_alive; then
      pid=$(pgrep -n -x wf-recorder)
      [[ $(rec_field state) == recording ]] && rec_state recording "$F" "$started" "$mode" "${1:-}" "" "" "$pid"
      if ! island_up; then
          # -p prints the id, so this exact notification can be replaced later
          id=$(notify-send -p -a swaync -u critical -t 0 \
                 "REC - recording the screen" "$(basename "$F")" 2>/dev/null) || id=""
          [[ -n $id ]] && printf '%s' "$id" >"$REC_ID"
      fi
  else
      # wf-recorder died: the supervising bash has called (or will call) rec-exited -> "failed".
      island_up || notify "Recording" "Failed to start - see $LOG"
  fi
}

# Only sends SIGINT (wf-recorder finalizes the moov atom and exits); rec-exited writes the
# state. If there is NO wf-recorder (e.g. a stale state left behind), nothing would call
# rec-exited, so call it directly and the state still finishes.
rec_stop() {
  if rec_alive; then
      pkill -INT -x wf-recorder
  else
      rec_exited none
  fi
}

rec_discard() {
  mkdir -p "$(dirname "$REC_DISCARD")"
  touch "$REC_DISCARD"
  rec_stop
}

# Called by the supervising bash (after wf-recorder HAS exited). The ONLY writer of the final state.
rec_exited() {                     # $1 = wf-recorder's exit code
  local F started mode geom size dur
  echo "wf-recorder exited: code=${1:-?}"
  # Two rec-exited can run at once (the supervising bash's, and rec-stop's when no
  # wf-recorder is left). Lock, and only finalize while the state is still "recording" —
  # otherwise a discard would be followed by a "Recording failed".
  mkdir -p "$(dirname "$REC_LOCK")"
  exec 9>"$REC_LOCK"
  flock 9
  if [[ ! -e $REC_STATE || $(rec_field state) != recording ]]; then
      echo "rec-exited: nothing left to finalize (state=[$(rec_field state)])"
      return 0
  fi
  F=$(rec_field file); started=$(rec_field started)
  mode=$(rec_field mode); geom=$(rec_field geometry)
  [[ -n $started ]] || started=0
  [[ -n $mode ]] || mode=screen
  if [[ -e $REC_DISCARD ]]; then
      # Read-only check BEFORE deleting: exactly ONE file, directly inside $VID, ending in .mp4.
      # Never glob. In [[ == ]] a `*` also matches "/", so "$VID"/*.mp4 would still let
      # "$VID/../x.mp4" through; only comparing normalized directories (realpath -m) is safe.
      if [[ -n $F && -f $F && $F == *.mp4 \
            && $(dirname -- "$(realpath -m -- "$F")") == "$(realpath -m -- "$VID")" ]]; then
          ls -l -- "$F"
          rm -f -- "$F"
      else
          echo "discard: skipping invalid path [$F]"
      fi
      rm -f "$REC_DISCARD" "$REC_STATE"
      rec_note_done "Recording discarded" "The recording was deleted"
      return
  fi
  # "saved" needs a file > 0 bytes AND a duration ffprobe can read. A crash mid-recording
  # leaves a file with bytes but no moov atom -> ffprobe fails -> "failed".
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F" 2>/dev/null)
  if [[ -n $F && -s $F && $dur =~ ^[0-9.]+$ ]]; then
      size=$(stat -c %s -- "$F")
      rec_state saved "$F" "$started" "$mode" "$geom" "$size" \
          "$(awk -v d="$dur" 'BEGIN { printf "%d", d * 1000 }')"
      rec_note_done "Recording stopped" "Saved to $VID"
  else
      rec_state failed "$F" "$started" "$mode" "$geom"
      rec_note_done "Recording" "Saving failed - see $LOG"
  fi
}

# CAPTURE OVERLAY (docs/capture-ui.md §2.2, §2.3)
# The overlay (Quickshell) only SHOWS the "freeze" image and calls back shot-crop; grim,
# slurp and wf-recorder still run ONLY in this file.
CAP_DIR="${XDG_RUNTIME_DIR:-/tmp}/capture"

capture_open() {                   # $1 = area|screen|window, $2 = photo|video
  local mode=${1:-area} kind=${2:-photo} out cc a b
  mkdir -p "$CAP_DIR"
  # ONE python call: the focused output AND whether the control centre is open.
  read -r out cc < <(python3 -c 'from wayfire import WayfireSocket
s = WayfireSocket()
cc = any(v.get("mapped") for v in s.list_views() if v.get("app-id") == "swaync-control-center")
print(s.get_focused_output()["name"], int(cc))' 2>/dev/null)
  # Close + wait 250 ms only when the control centre IS open (the old lesson: it would be in
  # the shot). Unknown (python failed) counts as open, to be safe.
  if [[ ${cc:-1} != 0 ]]; then close_panel; sleep 0.25; fi
  printf '%s' "$out" >"$CAP_DIR/freeze-output"
  if [[ $kind == photo ]]; then
      # Two shots IN PARALLEL, as PPM (~40 ms each, PNG ~200 ms), both BEFORE the overlay
      # shows, so the overlay can never be in the picture. freeze-cursor has the pointer.
      grim -t ppm ${out:+-o "$out"} "$CAP_DIR/freeze.ppm" & a=$!
      grim -t ppm -c ${out:+-o "$out"} "$CAP_DIR/freeze-cursor.ppm" & b=$!
      if ! wait "$a" || ! wait "$b"; then
          notify "Screenshot" "grim failed - see $LOG"; return 1
      fi
  fi
  qs_call capture show "$mode" "$kind" >/dev/null && return 0
  # `show` failed. Fall back to the old path only when Quickshell does NOT answer ping — if
  # it answers and show still fails, report it and DON'T fall back: never two UIs at once.
  if island_up; then
      echo "capture show failed although Quickshell answers ping: no fallback"
      notify "Screenshot" "The overlay did not open - see $LOG"
      return 1
  fi
  case "$kind:$mode" in
    photo:screen) exec bash "$ACTIONS" shot ;;
    photo:*)      exec bash "$ACTIONS" snip ;;
    video:screen) exec bash "$ACTIONS" rec ;;
    *)            exec bash "$ACTIONS" rec-area ;;
  esac
}

shot_crop() {                      # $1-$4 = x y w h (physical px), $5 = "cursor" -> the frame with the pointer
  local x=${1:-} y=${2:-} w=${3:-} h=${4:-} src="$CAP_DIR/freeze.ppm" F v
  [[ ${5:-} == cursor ]] && src="$CAP_DIR/freeze-cursor.ppm"
  for v in "$x" "$y" "$w" "$h"; do
      [[ $v =~ ^[0-9]+$ ]] || { notify "Screenshot" "Invalid selection - see $LOG"; return 1; }
  done
  (( w > 0 && h > 0 )) || { notify "Screenshot" "Empty selection"; return 1; }
  mkdir -p "$PIC"
  F="$PIC/$(date +%F_%H-%M-%S).png"
  if ! ffmpeg -v error -y -i "$src" -vf "crop=$w:$h:$x:$y" -frames:v 1 -update 1 "$F"; then
      notify "Screenshot" "Crop failed - see $LOG"; return 1
  fi
  wl-copy -t image/png <"$F"
  notify-send -a swaync -i "$F" "Screenshot" "$F" || true
}

# Run slurp and TELL APART "the user pressed Esc" from "slurp failed".
# The old version folded both into a silent `|| exit 0` -> a dying slurp showed nothing
# either, and that is exactly what had happened. slurp returns 1 when the user cancels, and
# another code on a real error (can't connect to Wayland, no layer-shell, etc.).
run_slurp() {
  local g rc
  g=$(slurp 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '%s' "$g"; return 0
  fi
  # MUST go to stderr: this function's stdout is captured by $( ), so a plain echo would
  # land in G instead of the log.
  echo "slurp failed: exit=$rc  output=[$g]" >&2
  # slurp 1.5 PRINTS "selection cancelled" on Esc (exit 1). The previous version only treated
  # "exit 1 + EMPTY output" as a cancel, so Esc was reported as "slurp failed (exit 1)".
  # Now: cancel = exit 1 AND the output contains "selection cancelled". Every other exit 1
  # STILL reports an error — catching real errors was the point of the original fix.
  if [[ $rc -eq 1 && $g == *"selection cancelled"* ]]; then
    return 1                                       # a normal cancel, silent
  fi
  notify "Screenshot" "slurp failed (exit $rc) - see $LOG"
  return 1
}

case "${1:-}" in

  # --- capture a selection with slurp ---
  snip)
      close_panel                    # close the control centre, or it would cover slurp
      sleep 0.25                     # wait for the layer surface to be fully gone
      mkdir -p "$PIC"
      G=$(run_slurp) || exit 0
      F="$PIC/$(date +%F_%H-%M-%S).png"
      grim -g "$G" - | tee "$F" | wl-copy -t image/png
      notify "Screenshot" "$F"
      ;;

  # --- capture the whole screen ---
  shot)
      close_panel
      sleep 0.25
      mkdir -p "$PIC"
      F="$PIC/$(date +%F_%H-%M-%S).png"
      grim - | tee "$F" | wl-copy -t image/png
      notify "Screenshot" "$F"
      ;;

  # --- toggle screen recording: full screen ---
  rec)
      if rec_alive; then rec_stop; else rec_start; fi
      ;;

  # --- toggle screen recording: a SELECTION via slurp ---
  rec-area)
      if rec_alive; then
          rec_stop
      else
          close_panel
          sleep 0.25                # let the control centre go before slurp draws
          G=$(run_slurp) || exit 0
          rec_start "$G"
      fi
      ;;

  # --- capture overlay (docs/capture-ui.md §2.2) ---
  capture-open) capture_open "${2:-area}" "${3:-photo}" ;;
  shot-crop)    shot_crop "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;

  # --- recording island (docs/capture-ui.md §2.2) ---
  # rec / rec-area above are still toggles as before, through these same functions.
  rec-start)   rec_alive || rec_start "${2:-}" ;;
  rec-stop)    rec_stop ;;
  rec-discard) rec_discard ;;
  rec-exited)  rec_exited "${2:-}" ;;     # only the supervising bash calls this

  # --- calendar + date and time, shown as ONE NOTIFICATION ---
  # swaync has NO calendar widget. The full widget list (README + man
  # swaync(5)): title, dnd, notifications, label, mpris, menubar, buttons-grid,
  # volume, backlight, slider. GTK4 has GtkCalendar, but swaync doesn't expose it.
  #
  # The only way to get a calendar "in swaync" WITHOUT bringing back the machinery that
  # rewrote config.json (dropped in the clean-up) is to send a notification: swaync shows
  # it itself, with no state to drift and no file rewritten.
  #
  # `-r <id>` replaces the old notification instead of stacking them on repeated presses.
  # Needs the CSS `.notification .body { font-family: monospace }` so the calendar columns line up.
  cal)
      CAL_ID="${XDG_RUNTIME_DIR:-/tmp}/swaync-cal-id"
      old_id=$(cat "$CAL_ID" 2>/dev/null) || old_id=""
      args=( -p -a swaync -t 20000 )
      [[ -n $old_id ]] && args+=( -r "$old_id" )
      # `cal` is from util-linux — always there on Arch. Guard anyway.
      cal_out=$(cal 2>/dev/null) || cal_out="('cal' not found — pacman -S util-linux)"
      body="$(date '+%H:%M   week %V')

$cal_out"
      new_id=$(notify-send "${args[@]}" "$(date '+%A, %d/%m/%Y')" "$body" 2>/dev/null) || new_id=""
      [[ -n $new_id ]] && printf '%s' "$new_id" >"$CAL_ID"
      ;;

  # --- clipboard history (cliphist + rofi) ---
  # cliphist is only a store + pipe, with no picker of its own. The picker here is rofi,
  # because you already use rofi for the launcher and the window switcher.
  #
  # `-display-columns 2`: cliphist list prints "<id>\t<100-character preview>".
  # rofi treats TAB as the column separator, so only column 2 is shown — but the chosen
  # string STILL carries the id, and that id is what `cliphist decode` uses to return
  # the original data byte for byte (leading/trailing whitespace included).
  #
  # Do NOT use the one-liner `cliphist list | rofi -dmenu | cliphist decode | wl-copy`:
  # on Esc rofi prints an empty string, decode returns nothing, and wl-copy WIPES the
  # current clipboard. Catch that and exit early.
  clip)
      sel=$(cliphist list | rofi -dmenu -i -display-columns 2 -p "clipboard" \
              -theme "$ROFI_THEME") || exit 0
      [[ -n $sel ]] || { echo "rofi: cancelled by the user"; exit 0; }
      printf '%s' "$sel" | cliphist decode | wl-copy
      ;;

  # --- delete one entry from the history ---
  clip-del)
      sel=$(cliphist list | rofi -dmenu -i -display-columns 2 -p "delete" \
              -mesg "Pick an entry to delete from the history" -theme "$ROFI_THEME") || exit 0
      [[ -n $sel ]] || exit 0
      printf '%s' "$sel" | cliphist delete
      ;;

  *)
      echo "usage: actions.sh <snip|shot|capture-open <area|screen|window> <photo|video>|shot-crop x y w h [cursor]|rec|rec-area|rec-start [geometry]|rec-stop|rec-discard|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>"
      exit 2
      ;;
esac
