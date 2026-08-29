#!/usr/bin/env bash
#
# build-wayfire.sh — build and install the Wayfire this config actually needs.
#
# The packaged wayfire will NOT run this configuration: wayfire.ini enables
# `spread-overview`, which exists only in the personal fork below. See
# docs/wayfire-build.md for the full story.
#
# Installs to /usr/local, which takes precedence over the packaged /usr copy.
# wlroots is built as a meson subproject (use_system_wlroots=disabled), so this
# does not depend on whichever wlroots version the repos currently carry.
#
#   ./scripts/build-wayfire.sh                 build + install (release)
#   ./scripts/build-wayfire.sh --debug         match the current on-disk build
#   ./scripts/build-wayfire.sh --src ~/src     use a different checkout root
#   ./scripts/build-wayfire.sh --no-install    build only

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="${HOME}/Documents/Projects"
WAYFIRE_REMOTE="https://github.com/SvnFrs/wayfire.git"
WAYFIRE_REF="master"
BUILDTYPE="release"
DO_INSTALL=1

while (( $# )); do
  case $1 in
    --debug)      BUILDTYPE=debug ;;
    --release)    BUILDTYPE=release ;;
    --src)        SRC_ROOT="$2"; shift ;;
    --ref)        WAYFIRE_REF="$2"; shift ;;
    --no-install) DO_INSTALL=0 ;;
    -h|--help)    sed -n '3,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

B=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }

command -v meson >/dev/null || { echo "meson missing — run: ./scripts/bootstrap.sh packages" >&2; exit 1; }

step "build dependencies"
missing=()
while read -r pkg; do
  [[ -z $pkg || $pkg == \#* ]] && continue
  pkg="${pkg%%#*}"; pkg="${pkg// /}"; [[ -z $pkg ]] && continue
  pacman -Qq "$pkg" &>/dev/null || missing+=("$pkg")
done < "$REPO/scripts/packages/wayfire-build.txt"
if (( ${#missing[@]} )); then
  echo "  installing: ${missing[*]}"
  sudo pacman -S --needed --noconfirm -- "${missing[@]}"
else
  ok "all build dependencies present"
fi

# ── source ───────────────────────────────────────────────────────────────────
SRC="$SRC_ROOT/wayfire"
step "source: $SRC"
if [[ -d $SRC/.git ]]; then
  ok "checkout exists ($(git -C "$SRC" rev-parse --short HEAD))"
  if [[ -n $(git -C "$SRC" status --porcelain) ]]; then
    warn "working tree has local changes — leaving them alone, not pulling"
  else
    git -C "$SRC" fetch --recurse-submodules origin "$WAYFIRE_REF"
    git -C "$SRC" checkout "$WAYFIRE_REF"
    git -C "$SRC" pull --ff-only origin "$WAYFIRE_REF"
  fi
else
  mkdir -p "$SRC_ROOT"
  git clone --recurse-submodules "$WAYFIRE_REMOTE" "$SRC"
  git -C "$SRC" checkout "$WAYFIRE_REF"
fi
git -C "$SRC" submodule update --init --recursive
ok "at $(git -C "$SRC" rev-parse --short HEAD) — $(git -C "$SRC" log -1 --format=%s)"

# ── configure + build ────────────────────────────────────────────────────────
# These options mirror the build that is installed today. use_system_wlroots is
# disabled on purpose: wayfire master tracks wlroots more closely than the repos
# do, and pinning to the bundled subproject keeps the two in step.
step "configure ($BUILDTYPE)"
BUILD="$SRC/build"
meson_args=(
  --prefix=/usr/local
  --libdir=lib
  "--buildtype=$BUILDTYPE"
  -Duse_system_wlroots=disabled
  -Denable_gles32=true
  -Denable_openmp=true
  -Dtests=enabled
)
if [[ -d $BUILD ]]; then
  meson setup --reconfigure "${meson_args[@]}" "$BUILD" "$SRC"
else
  meson setup "${meson_args[@]}" "$BUILD" "$SRC"
fi

step "compile"
ninja -C "$BUILD"

if (( DO_INSTALL )); then
  step "install to /usr/local"
  sudo ninja -C "$BUILD" install
  sudo ldconfig
  ok "installed"

  # A packaged wayfire alongside the source build is a live hazard: if
  # /usr/local/bin ever leaves PATH you silently launch a compositor that
  # cannot load this config.
  if pacman -Qq wayfire &>/dev/null; then
    warn "the 'wayfire' package is ALSO installed and is not what runs."
    warn "consider: sudo pacman -Rns wayfire wayfire-plugins-extra wf-config wlroots0.19"
  fi

  step "verify"
  echo "  binary : $(command -v wayfire)"
  echo "  version: $(wayfire --version 2>&1 | head -1)"
  missing_plugins=()
  while read -r p; do
    [[ -e /usr/local/lib/wayfire/lib$p.so ]] || missing_plugins+=("$p")
  done < <(awk '/^plugins *=/{f=1} f{gsub(/[\\=]/," "); gsub(/^ *plugins */,""); print} f&&!/\\$/{f=0}' \
             "$HOME/.config/wayfire.ini" 2>/dev/null | tr ' ' '\n' | grep -vE '^(plugins|)$' | sort -u)
  if (( ${#missing_plugins[@]} )); then
    warn "plugins in wayfire.ini with no .so in /usr/local/lib/wayfire: ${missing_plugins[*]}"
  else
    ok "every plugin in wayfire.ini is present"
  fi
fi

step "done"
echo "  Log out and back in on tty1 to pick up the new build."
