#!/usr/bin/env bash
# ~/.config/swaync/actions.sh
# Cac hanh dong "nang" cua swaync (screenshot / screen record), tach khoi
# config.json.
#
# Dung: actions.sh <snip|shot|rec|rec-area|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>
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

rec_start() {                      # $1 = geometry "x,y WxH" (bo trong = full screen)
  close_panel
  mkdir -p "$VID"
  local F MON args id
  F="$VID/$(date +%F_%H-%M-%S).mp4"
  MON="$(pactl get-default-sink).monitor"      # desktop audio, KHONG phai mic
  args=( -D -r 60 "--audio=$MON" -f "$F" )
  [[ -n ${1:-} ]] && args+=( -g "$1" )
  setsid -f wf-recorder "${args[@]}"
  sleep 0.8
  # `setsid -f` tra ve ngay lap tuc nen exit code cua no KHONG cho biet
  # wf-recorder da khoi dong duoc hay chua. Phai kiem tra process that.
  if rec_alive; then
      # -p in ra id de sau nay thay the dung cai notification nay
      id=$(notify-send -p -a swaync -u critical -t 0 \
             "REC - dang ghi man hinh" "$(basename "$F")" 2>/dev/null) || id=""
      [[ -n $id ]] && printf '%s' "$id" >"$REC_ID"
  else
      notify "Recording" "KHOI DONG THAT BAI - xem $LOG"
  fi
}

rec_stop() {
  pkill -INT -x wf-recorder        # SIGINT -> wf-recorder finalize moov atom
  local id
  id=$(cat "$REC_ID" 2>/dev/null) || id=""
  if [[ -n $id ]]; then
      notify-send -a swaync -r "$id" -t 4000 "Da dung ghi" "Da luu vao $VID" || true
  else
      notify "Recording" "Da dung va luu"
  fi
  rm -f "$REC_ID"
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
  if [[ $rc -eq 1 && -z $g ]]; then
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
      echo "usage: actions.sh <snip|shot|rec|rec-area|cal|clip|clip-del|vol-up|vol-down|vol-mute|mic-mute>"
      exit 2
      ;;
esac