#!/usr/bin/env bash
# ~/.config/swaync/actions.sh
# Cac hanh dong "nang" cua swaync (screenshot / screen record), tach khoi
# config.json.
#
# Dung: actions.sh <snip|shot|rec|rec-area|rec-start [geometry]|rec-stop|rec-discard|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>
#
# TAI SAO PHAI TACH RA FILE RIENG:
#   1. Nhoi mot pipeline nhieu lenh vao chuoi JSON thi khong ai debug duoc:
#      swaync spawn qua GLib, stdout/stderr cua child di vao hu vo. Lenh chet
#      vi bat ky ly do gi -> ban chi thay "khong co gi xay ra".
#   2. File nay ghi TOAN BO stdout+stderr+trace vao log. Bam nut mot lan roi
#      doc log la biet chinh xac hong o dau.
#   3. Chay duoc doc lap tu terminal de doi chieu:  ~/.config/swaync/actions.sh snip
#
# LOG:  ~/.cache/swaync-actions.log   (tu cat con 200 dong)

set -u

# ============================ VOLUME =========================================
# Xu ly TRUOC khoi logging: phim volume bam rat nhieu lan, khong nen do vao log.
#
# TAI SAO KHONG DUNG `+5%` / `-5%` TUONG DOI:
#   Dang tuong doi cong delta vao TUNG kenh roi lam tron rieng. ALSA Master tren
#   Intel HDA chi co vai chuc buoc nguyen (vd 0-87), 5% = 4.35 buoc -> front-left
#   va front-right lam tron khac nhau va lech dan. Lech roi thi khong tu ve lai.
#   Dang TUYET DOI khong co tien to kenh (`pactl set-sink-volume SINK 65%`) ap
#   CUNG MOT gia tri cho MOI kenh, nen hai ben khong the lech nhau. Doc gia tri
#   hien tai -> cong -> ghi tuyet doi. Dung chan tren/duoi luon.
#
# Kiem chung lech kenh (chay truoc va sau khi bam phim vai lan):
#     pactl get-sink-volume @DEFAULT_SINK@ | head -1
#   front-left != front-right = da lech. Can bang lai ngay:
#     pactl set-sink-volume @DEFAULT_SINK@ 100%
VOL_STEP="${VOL_STEP:-5}"

vol_cur() {
  pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null \
    | grep -o '[0-9]\+%' | head -1 | tr -d '%'
}

vol_step() {                       # $1 = delta nguyen, vd 5 hoac -5
  local c n
  c=$(vol_cur)
  [[ $c =~ ^[0-9]+$ ]] || exit 1   # khong doc duoc thi thoi, dung doan
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

# Xoay log: giu 200 dong cuoi, khong de file phinh vo han.
if [[ -f $LOG ]]; then
  tail -n 200 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
fi

# Tu day tro di MOI thu deu vao log.
# Luu y: pipeline (grim | tee | wl-copy -t image/png) tu set stdout rieng, khong bi anh huong.
exec >>"$LOG" 2>&1

echo "===== $(date '+%F %T')  argv=[$*]"
echo "      WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<CHUA SET>}"
echo "      XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-<CHUA SET>}"
echo "      PATH=$PATH"
set -x

# xdg-user-dir tra ve $HOME khi bien tuong ung KHONG co trong
# ~/.config/user-dirs.dirs -> file se roi thang vao ~/Screenshots, ~/Recordings.
# Log cua ban chung minh dieu do dang xay ra:  PIC=/home/thai/Screenshots
# Ham nay phat hien truong hop do va fallback ve duong dan chuan.
xdg_dir() {                       # $1 = ten XDG, $2 = duong dan du phong
  local d
  d=$(xdg-user-dir "$1" 2>/dev/null)
  [[ -z $d || $d == "$HOME" || $d == "$HOME/" ]] && d="$HOME/$2"
  printf '%s' "$d"
}
PIC="$(xdg_dir PICTURES Pictures)/Screenshots"
VID="$(xdg_dir VIDEOS Videos)/Recordings"

# Theme cho rofi. `rofi -dmenu` tran KHONG dung theme ma launcher cua ban dat —
# launcher truyen -theme rieng nen config do khong ap vao day, va rofi roi ve
# theme built-in (nen kem, khong bo goc — nhin nhu dmenu chua rice).
# Tro thang vao file theme. Doi sang theme co san cua ban thi sua dong nay.
ROFI_THEME="${ROFI_THEME:-$HOME/.config/rofi/config/clipboard.rasi}"

# notify-send khong duoc phep lam chet script neu daemon chua san sang
notify() { notify-send -a swaync "$1" "$2" || true; }

# Dong control center truoc khi chup/quay.
#
# LOI DA TUNG XAY RA O DAY: goi `swaync-client -cp` tran.
# swaync-client MAC DINH CHO swaync xuat hien tren D-Bus — co han co
# `-sw/--skip-wait` de KHONG cho. Nen khi swaync khong chay (vd vua kill de
# debug, hoac autostart chua kip), dong nay TREO VO HAN. `|| true` khong cuu
# duoc gi vi lenh khong bao gio tra ve. Ket qua: snip/shot/rec-area chet im
# lang, log dung ngay tai dong do, con `cal` (khong goi swaync-client) van chay.
#
# Hai lop bao ve: -sw de khong cho, va timeout de chan moi truong hop con lai.
close_panel() { timeout 1 swaync-client -cp -sw >/dev/null 2>&1 || true; }

# `pgrep -x` KHOP CA ZOMBIE: tien trinh da chet nhung chua duoc cha reap van
# con entry trong /proc. Phat hien khi test: wf-recorder gia lap chet ngay lap
# tuc, pgrep van bao "dang chay" -> script bao "Bat dau" trong khi that bai.
# Tren Arch systemd la PID 1 nen orphan duoc reap ngay, nhung loc ra van dung hon.
rec_alive() {
  local p s
  for p in $(pgrep -x wf-recorder 2>/dev/null); do
    s=$(ps -o stat= -p "$p" 2>/dev/null)
    [[ $s == Z* ]] || return 0
  done
  return 1
}

# wf-recorder KHONG nhan "-a DEVICE" (dau cach). Tham so cua -a la OPTIONAL nen
# getopt chi lay khi viet dinh lien: -a<DEVICE> hoac --audio=<DEVICE>.
# Bang chung trong log cua ban: truyen "-a alsa_output....monitor" ma wf-recorder
# in ra "Using PulseAudio device: default" -> chuoi bi bo qua, no quay MICRO.
# CHI BAO DANG GHI HINH
# Khong dung widget nao trong swaync ca — chi la mot notification urgency=critical.
# config.json dat "timeout-critical": 0 nen no NAM LAI tren man hinh suot thoi
# gian quay. Luc dung, `notify-send -r <id>` thay the chinh no bang mot thong bao
# tam thoi. Khong co state nao de lech, khong phai ghi lai config.json.
REC_ID="${XDG_RUNTIME_DIR:-/tmp}/swaync-rec-id"

# TRANG THAI CHO RECORDING ISLAND (docs/capture-ui.md §2.2)
# Island (Quickshell, ~/.config/quickshell/enhalation) chi DOC file nay, khong bao
# gio tu chay recorder: script nay van la thu DUY NHAT chay wf-recorder. Ghi atomic
# (tmp + mv) de island khong bao gio doc phai mot file ghi do dang.
# Khi island KHONG chay (`ping` that bai), dung lai notification cu — khong bao
# gio co ca hai cung luc.
#
# AI GHI TRANG THAI CUOI: CHI `rec-exited`. rec_start chay wf-recorder DUOI mot
# bash giam sat; khi wf-recorder thoat vi bat ky ly do gi (Stop, huy, crash) bash
# do goi `actions.sh rec-exited <code>` — luc do file da finalize xong. Nen khong
# co duong nao de island ket mai o "REC".
REC_STATE="${XDG_RUNTIME_DIR:-/tmp}/capture/rec.json"
REC_DISCARD="${XDG_RUNTIME_DIR:-/tmp}/capture/discard"
REC_LOCK="${XDG_RUNTIME_DIR:-/tmp}/capture/rec.lock"
ACTIONS="$(realpath "${BASH_SOURCE[0]}")"

json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

# rec_state <state> <file> <started ms> <mode> [geometry] [size] [duration_ms] [pid]
# pid chi de doc log/debug; khong co gi poll no.
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

rec_field() {                      # $1 = key trong rec.json; rong neu khong co
  python3 -c 'import json, sys
try: v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception: v = None
print("" if v is None else v)' "$REC_STATE" "$1" 2>/dev/null
}

island_up() { timeout 1 qs -c enhalation ipc call rec ping >/dev/null 2>&1; }

# Notification "REC" cu (neu co): island dang chay -> dong no; khong -> thay bang $1/$2.
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

rec_start() {                      # $1 = geometry "x,y WxH" (bo trong = full screen)
  close_panel
  mkdir -p "$VID"
  local F MON args id started pid mode=screen
  F="$VID/$(date +%F_%H-%M-%S).mp4"
  MON="$(pactl get-default-sink).monitor"      # desktop audio, KHONG phai mic
  args=( -D -r 60 "--audio=$MON" -f "$F" )
  [[ -n ${1:-} ]] && { args+=( -g "$1" ); mode=area; }
  started=$(date +%s%3N)
  rm -f "$REC_DISCARD"
  # Ghi "recording" TRUOC khi chay: neu wf-recorder chet ngay, rec-exited doc dung
  # file cua LAN NAY (khong phai file cu con trong rec.json) va ghi "failed".
  rec_state recording "$F" "$started" "$mode" "${1:-}"
  # $0 = duong dan script nay, "$@" = dung cac args o tren (giu nguyen --audio=).
  # Goi `bash "$0"` chu khong goi thang script: bit thuc thi co the mat (xem wayfire.ini).
  setsid -f bash -c 'wf-recorder "$@"; bash "$0" rec-exited $?' "$ACTIONS" "${args[@]}"
  sleep 0.8
  # `setsid -f` tra ve ngay lap tuc nen exit code cua no KHONG cho biet
  # wf-recorder da khoi dong duoc hay chua. Phai kiem tra process that.
  if rec_alive; then
      pid=$(pgrep -n -x wf-recorder)
      [[ $(rec_field state) == recording ]] && rec_state recording "$F" "$started" "$mode" "${1:-}" "" "" "$pid"
      if ! island_up; then
          # -p in ra id de sau nay thay the dung cai notification nay
          id=$(notify-send -p -a swaync -u critical -t 0 \
                 "REC - dang ghi man hinh" "$(basename "$F")" 2>/dev/null) || id=""
          [[ -n $id ]] && printf '%s' "$id" >"$REC_ID"
      fi
  else
      # wf-recorder da chet: bash giam sat da (hoac sap) goi rec-exited -> "failed".
      island_up || notify "Recording" "KHOI DONG THAT BAI - xem $LOG"
  fi
}

# Chi gui SIGINT (wf-recorder finalize moov atom roi thoat); rec-exited ghi trang
# thai. Neu KHONG co wf-recorder nao (vd state cu con sot), khong ai goi rec-exited
# ca, nen goi no truc tiep de state van ket thuc.
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

# Bash giam sat goi (sau khi wf-recorder DA thoat). Thu DUY NHAT ghi trang thai cuoi.
rec_exited() {                     # $1 = exit code cua wf-recorder
  local F started mode geom size dur
  echo "wf-recorder da thoat: code=${1:-?}"
  # Hai rec-exited co the chay cung luc (cua bash giam sat, va cua rec-stop khi khong
  # con wf-recorder). Khoa lai, va chi ket thuc khi state van la "recording" — neu
  # khong, mot lan huy se bi mot "Recording failed" noi theo sau.
  mkdir -p "$(dirname "$REC_LOCK")"
  exec 9>"$REC_LOCK"
  flock 9
  if [[ ! -e $REC_STATE || $(rec_field state) != recording ]]; then
      echo "rec-exited: khong con gi de ket thuc (state=[$(rec_field state)])"
      return 0
  fi
  F=$(rec_field file); started=$(rec_field started)
  mode=$(rec_field mode); geom=$(rec_field geometry)
  [[ -n $started ]] || started=0
  [[ -n $mode ]] || mode=screen
  if [[ -e $REC_DISCARD ]]; then
      # Kiem tra read-only TRUOC khi xoa: dung MOT file, nam NGAY trong $VID, duoi .mp4.
      # Khong bao gio glob. Trong [[ == ]] dau `*` khop ca "/", nen "$VID"/*.mp4 van
      # cho "$VID/../x.mp4" lot qua; so thu muc da chuan hoa (realpath -m) moi chac.
      if [[ -n $F && -f $F && $F == *.mp4 \
            && $(dirname -- "$(realpath -m -- "$F")") == "$(realpath -m -- "$VID")" ]]; then
          ls -l -- "$F"
          rm -f -- "$F"
      else
          echo "discard: bo qua duong dan khong hop le [$F]"
      fi
      rm -f "$REC_DISCARD" "$REC_STATE"
      rec_note_done "Da huy ghi" "Da xoa ban ghi"
      return
  fi
  # "saved" can file > 0 byte VA ffprobe doc duoc duration. Crash giua chung de lai
  # file co byte nhung khong co moov atom -> ffprobe that bai -> "failed".
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$F" 2>/dev/null)
  if [[ -n $F && -s $F && $dur =~ ^[0-9.]+$ ]]; then
      size=$(stat -c %s -- "$F")
      rec_state saved "$F" "$started" "$mode" "$geom" "$size" \
          "$(awk -v d="$dur" 'BEGIN { printf "%d", d * 1000 }')"
      rec_note_done "Da dung ghi" "Da luu vao $VID"
  else
      rec_state failed "$F" "$started" "$mode" "$geom"
      rec_note_done "Recording" "LUU THAT BAI - xem $LOG"
  fi
}

# Chay slurp va PHAN BIET "nguoi dung bam Esc" voi "slurp that bai".
# Ban cu gop ca hai thanh `|| exit 0` im lang -> slurp chet cung khong thay gi,
# ma do dung la truong hop da xay ra. slurp tra ve 1 khi nguoi dung huy, va ma
# khac khi loi that (khong ket noi duoc Wayland, thieu layer-shell, v.v.).
run_slurp() {
  local g rc
  g=$(slurp 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '%s' "$g"; return 0
  fi
  # PHAI ra stderr: stdout cua ham nay dang bi $( ) bat, echo binh thuong se
  # chui vao bien G thay vi vao log.
  echo "slurp that bai: exit=$rc  output=[$g]" >&2
  # slurp 1.5 IN RA "selection cancelled" khi bam Esc (exit 1). Ban truoc chi coi
  # "exit 1 + output RONG" la huy, nen Esc bi bao thanh loi "slurp loi (exit 1)".
  # Gio: huy = exit 1 VA output chua "selection cancelled". Moi exit 1 khac VAN bao
  # loi — bat duoc loi that moi la ly do cua ban sua goc.
  if [[ $rc -eq 1 && $g == *"selection cancelled"* ]]; then
    return 1                                       # huy binh thuong, im lang
  fi
  notify "Screenshot" "slurp loi (exit $rc) - xem $LOG"
  return 1
}

case "${1:-}" in

  # --- chup vung chon bang slurp ---
  snip)
      close_panel                    # dong control center, neu con no se che slurp
      sleep 0.25                     # doi layer-surface bien mat han
      mkdir -p "$PIC"
      G=$(run_slurp) || exit 0
      F="$PIC/$(date +%F_%H-%M-%S).png"
      grim -g "$G" - | tee "$F" | wl-copy -t image/png
      notify "Screenshot" "$F"
      ;;

  # --- chup nguyen man hinh ---
  shot)
      close_panel
      sleep 0.25
      mkdir -p "$PIC"
      F="$PIC/$(date +%F_%H-%M-%S).png"
      grim - | tee "$F" | wl-copy -t image/png
      notify "Screenshot" "$F"
      ;;

  # --- toggle ghi man hinh: toan man hinh ---
  rec)
      if rec_alive; then rec_stop; else rec_start; fi
      ;;

  # --- toggle ghi man hinh: VUNG CHON bang slurp ---
  rec-area)
      if rec_alive; then
          rec_stop
      else
          close_panel
          sleep 0.25                # doi control center bien mat truoc khi slurp ve
          G=$(run_slurp) || exit 0
          rec_start "$G"
      fi
      ;;

  # --- recording island (docs/capture-ui.md §2.2) ---
  # rec / rec-area o tren van la toggle nhu cu, qua cung cac ham nay.
  rec-start)   rec_alive || rec_start "${2:-}" ;;
  rec-stop)    rec_stop ;;
  rec-discard) rec_discard ;;
  rec-exited)  rec_exited "${2:-}" ;;     # chi bash giam sat goi

  # --- lich + ngay gio, hien duoi dang MOT NOTIFICATION ---
  # swaync KHONG co widget calendar. Danh sach widget day du (README + man
  # swaync(5)): title, dnd, notifications, label, mpris, menubar, buttons-grid,
  # volume, backlight, slider. GTK4 co GtkCalendar nhung swaync khong expose ra.
  #
  # Cach duy nhat de co lich "trong swaync" ma KHONG phai dung lai co may ghi de
  # config.json (thu da bo o buoc don dep) la ban mot notification: no hien ra
  # bang chinh swaync, khong co state nao de lech, khong file nao bi ghi lai.
  #
  # `-r <id>` thay the notification cu thay vi chong len nhau khi bam nhieu lan.
  # Can CSS `.notification .body { font-family: monospace }` de cot lich thang hang.
  cal)
      CAL_ID="${XDG_RUNTIME_DIR:-/tmp}/swaync-cal-id"
      old_id=$(cat "$CAL_ID" 2>/dev/null) || old_id=""
      args=( -p -a swaync -t 20000 )
      [[ -n $old_id ]] && args+=( -r "$old_id" )
      # `cal` thuoc goi util-linux — luon co tren Arch. Van chan neu thieu.
      cal_out=$(cal 2>/dev/null) || cal_out="(khong tim thay lenh 'cal' — pacman -S util-linux)"
      body="$(date '+%H:%M   tuan %V')

$cal_out"
      new_id=$(notify-send "${args[@]}" "$(date '+%A, %d/%m/%Y')" "$body" 2>/dev/null) || new_id=""
      [[ -n $new_id ]] && printf '%s' "$new_id" >"$CAL_ID"
      ;;

  # --- clipboard history (cliphist + rofi) ---
  # cliphist chi la kho luu + pipe, khong co picker rieng. Picker o day la rofi
  # vi ban da dung rofi cho launcher/window-switcher.
  #
  # `-display-columns 2`: cliphist list xuat "<id>\t<preview 100 ky tu>".
  # Rofi coi TAB la dau tach cot, nen chi hien cot 2 cho de nhin — nhung chuoi
  # duoc chon VAN giu nguyen ca id, va id do moi la thu `cliphist decode` dung
  # de tra ve du lieu goc byte-for-byte (giu ca khoang trang dau/cuoi).
  #
  # KHONG dung one-liner `cliphist list | rofi -dmenu | cliphist decode | wl-copy`:
  # bam Esc thi rofi xuat chuoi rong, decode tra ve rong, va wl-copy XOA SACH
  # clipboard hien tai. Bat va thoat som.
  clip)
      sel=$(cliphist list | rofi -dmenu -i -display-columns 2 -p "clipboard" \
              -theme "$ROFI_THEME") || exit 0
      [[ -n $sel ]] || { echo "rofi: nguoi dung huy"; exit 0; }
      printf '%s' "$sel" | cliphist decode | wl-copy
      ;;

  # --- xoa mot muc khoi lich su ---
  clip-del)
      sel=$(cliphist list | rofi -dmenu -i -display-columns 2 -p "xoa" \
              -mesg "Chon muc de XOA khoi lich su" -theme "$ROFI_THEME") || exit 0
      [[ -n $sel ]] || exit 0
      printf '%s' "$sel" | cliphist delete
      ;;

  *)
      echo "usage: actions.sh <snip|shot|rec|rec-area|rec-start [geometry]|rec-stop|rec-discard|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>"
      exit 2
      ;;
esac