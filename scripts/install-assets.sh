#!/usr/bin/env bash
#
# install-assets.sh — reinstall the large, reinstallable fonts & icon themes
# that are intentionally NOT vendored in this repo (to keep it small).
#
# Run once on a fresh Arch install after cloning the dotfiles.
# Idempotent: safe to re-run.
#
# What this installs:
#   - JetBrains Mono Nerd Font (Mono + NL)  -> via pacman
#   - Catppuccin-SE icon theme              -> GitHub release -> ~/.icons
#   - GoogleDot cursor themes (Black+White) -> GitHub release -> ~/.icons
#
# Still vendored in the repo (not freely re-downloadable, so kept in git):
#   - Cartograph CF Nerd Font (commercial)
#   - Graphite-Recolored-* icon themes (custom recolors)
#   - oreo_*_cursors (custom "spark" variants)

set -euo pipefail

ICONS_DIR="$HOME/.icons"
mkdir -p "$ICONS_DIR"

note() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# --- helper: download a release asset and extract it into ~/.icons ---------
fetch_icon_archive() {
  local url="$1" name="$2"
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  note "Installing icon theme: $name"
  curl -fL --retry 3 -o "$tmp/$name" "$url"
  case "$name" in
    *.tar.bz2) tar -xjf "$tmp/$name" -C "$ICONS_DIR" ;;
    *.tar.gz)  tar -xzf "$tmp/$name" -C "$ICONS_DIR" ;;
    *.tar.xz)  tar -xJf "$tmp/$name" -C "$ICONS_DIR" ;;
    *) echo "unknown archive type: $name" >&2; return 1 ;;
  esac
}

# --- 1. JetBrains Mono Nerd Font (official 'extra' repo) -------------------
note "Installing JetBrains Mono Nerd Font (ttf-jetbrains-mono-nerd)"
sudo pacman -S --needed --noconfirm ttf-jetbrains-mono-nerd

# --- 2. Catppuccin-SE icon theme -------------------------------------------
fetch_icon_archive \
  "https://github.com/ljmill/catppuccin-icons/releases/latest/download/Catppuccin-SE.tar.bz2" \
  "Catppuccin-SE.tar.bz2"

# --- 3. GoogleDot cursor themes (Black + White) ----------------------------
for variant in Black White; do
  fetch_icon_archive \
    "https://github.com/ful1e5/Google_Cursor/releases/latest/download/GoogleDot-${variant}.tar.gz" \
    "GoogleDot-${variant}.tar.gz"
done

# --- refresh caches --------------------------------------------------------
note "Refreshing font cache"
fc-cache -f >/dev/null 2>&1 || true

note "Done. Installed fonts + icon themes into ~/.icons and the system font dir."
echo "    Vendored extras (Cartograph CF, Graphite-Recolored-*, oreo_*) ship with the repo."
