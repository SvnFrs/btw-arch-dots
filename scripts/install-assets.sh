#!/usr/bin/env bash
#
# install-assets.sh — fetch the fonts and icon themes this repo deliberately
# does NOT vendor, because they are freely redistributable and would otherwise
# add tens of megabytes to every clone.
#
# Idempotent. Safe to re-run.
#
#   installed here          | why it is not in git
#   ------------------------|-------------------------------------------------
#   JetBrains Mono Nerd     | in the official repos (ttf-jetbrains-mono-nerd)
#   Catppuccin-SE icons     | GitHub release, ~30 MB
#   GoogleDot cursors       | GitHub release, two variants
#
# Still vendored in the repo, because they are NOT re-downloadable:
#   Cartograph CF Nerd Font        home/.local/share/fonts/cartograph-cf/
#   Graphite-Recolored-* cursors   home/.icons/
#   oreo_* cursors                 home/.icons/
# Those are deployed by `dots link`, not by this script.

set -euo pipefail

ICONS_DIR="$HOME/.icons"
mkdir -p "$ICONS_DIR"

B=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "required tool missing: $1" >&2; exit 1; }; }
need curl; need tar

# Download a release archive and unpack it into ~/.icons.
# Skips the download entirely when the theme directory already exists.
fetch_icon_theme() {
  local url=$1 archive=$2 dir=$3
  if [[ -d $ICONS_DIR/$dir ]]; then ok "$dir already installed"; return 0; fi
  step "installing icon theme: $dir"
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064   # expand tmp now, on purpose
  trap "rm -rf '$tmp'" RETURN
  curl -fL --retry 3 --proto '=https' --tlsv1.2 -o "$tmp/$archive" "$url"
  case "$archive" in
    *.tar.bz2) tar -xjf "$tmp/$archive" -C "$ICONS_DIR" ;;
    *.tar.gz)  tar -xzf "$tmp/$archive" -C "$ICONS_DIR" ;;
    *.tar.xz)  tar -xJf "$tmp/$archive" -C "$ICONS_DIR" ;;
    *) echo "unknown archive type: $archive" >&2; return 1 ;;
  esac
  [[ -d $ICONS_DIR/$dir ]] && ok "installed $dir" || warn "archive unpacked but $dir is not there — check its layout"
}

# ── 1. JetBrains Mono Nerd Font ──────────────────────────────────────────────
step "JetBrains Mono Nerd Font"
if pacman -Qq ttf-jetbrains-mono-nerd &>/dev/null; then
  ok "ttf-jetbrains-mono-nerd already installed"
else
  sudo pacman -S --needed --noconfirm ttf-jetbrains-mono-nerd
fi
# A hand-copied set in ~/.local shadows the package and drifts out of date.
if compgen -G "$HOME/.local/share/fonts/nerd-fonts/JetBrainsMono*" >/dev/null; then
  warn "there is also a manual copy in ~/.local/share/fonts/nerd-fonts/"
  warn "the package version in /usr is enough — delete that directory to avoid duplicate faces"
fi

# ── 2. Catppuccin-SE icon theme ──────────────────────────────────────────────
fetch_icon_theme \
  "https://github.com/ljmill/catppuccin-icons/releases/latest/download/Catppuccin-SE.tar.bz2" \
  "Catppuccin-SE.tar.bz2" "Catppuccin-SE"

# ── 3. GoogleDot cursors ─────────────────────────────────────────────────────
# wayfire.ini and the GTK settings both name GoogleDot-White; Black is kept
# because ~/.icons/default/index.theme inherits from it.
for variant in Black White; do
  fetch_icon_theme \
    "https://github.com/ful1e5/Google_Cursor/releases/latest/download/GoogleDot-${variant}.tar.gz" \
    "GoogleDot-${variant}.tar.gz" "GoogleDot-${variant}"
done

# ── refresh ──────────────────────────────────────────────────────────────────
step "refreshing font cache"
fc-cache -f >/dev/null 2>&1 || true
ok "done"

cursor="$(sed -n 's/^ *cursor_theme *= *//p' "$HOME/.config/wayfire.ini" 2>/dev/null | head -1)"
if [[ -n $cursor && ! -d $ICONS_DIR/$cursor && ! -d /usr/share/icons/$cursor ]]; then
  warn "wayfire.ini asks for cursor theme '$cursor' which is still not present"
fi
