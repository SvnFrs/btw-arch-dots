#!/usr/bin/env bash
#
# bootstrap.sh — take a freshly installed Arch system to this desktop.
#
# Assumes: Arch is installed and booted, you have a user in wheel with sudo, and
# you have cloned this repo. For the base install itself see docs/installation.md.
#
# Idempotent — safe to re-run. Nothing here overwrites a config: `dots link`
# moves anything already in place into .backups/ first.
#
#   ./scripts/bootstrap.sh            everything
#   ./scripts/bootstrap.sh packages   just the package sets
#   ./scripts/bootstrap.sh link       just deploy the dotfiles
#   ./scripts/bootstrap.sh --dry-run  print what would happen

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DRY=0
STAGE=all
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    packages|aur|shell|link|services|assets|all) STAGE="$a" ;;
    -h|--help) sed -n '3,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

B=$'\033[34m'; G=$'\033[32m'; Y=$'\033[33m'; N=$'\033[0m'
step() { printf '\n%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
skip() { printf '  %s·%s %s\n' "$Y" "$N" "$*"; }
run()  { if (( DRY )); then printf '  would run: %s\n' "$*"; else "$@"; fi; }

want() { [[ $STAGE == all || $STAGE == "$1" ]]; }

# ── sanity ────────────────────────────────────────────────────────────────────
[[ -f /etc/arch-release ]] || { echo "this script targets Arch Linux" >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo "run as your normal user, not root (it calls sudo itself)" >&2; exit 1; }

# ── packages ──────────────────────────────────────────────────────────────────
# Routing is automatic: anything the configured repos know about goes through
# pacman, the rest through yay. That way the package lists do not have to track
# which things happen to be in Chaotic-AUR this month.
install_list() {
  local file="$1" pkg
  local -a repo=() aur=()
  while read -r pkg; do
    [[ -z $pkg || $pkg == \#* ]] && continue
    pkg="${pkg%%#*}"; pkg="${pkg// /}"
    [[ -z $pkg ]] && continue
    if pacman -Qq "$pkg" &>/dev/null; then continue; fi          # already installed
    if pacman -Si "$pkg" &>/dev/null; then repo+=("$pkg"); else aur+=("$pkg"); fi
  done < "$file"

  if (( ${#repo[@]} )); then
    printf '  pacman: %s\n' "${repo[*]}"
    run sudo pacman -S --needed --noconfirm -- "${repo[@]}"
  fi
  if (( ${#aur[@]} )); then
    if command -v yay &>/dev/null; then
      printf '  yay:    %s\n' "${aur[*]}"
      run yay -S --needed --noconfirm -- "${aur[@]}"
    else
      skip "yay missing, cannot install: ${aur[*]}"
    fi
  fi
  (( ${#repo[@]} || ${#aur[@]} )) || ok "$(basename "$file"): everything already installed"
}

if want packages; then
  step "yay (AUR helper)"
  if command -v yay &>/dev/null; then ok "yay already installed"
  else
    run sudo pacman -S --needed --noconfirm git base-devel
    tmp="$(mktemp -d)"
    run git clone --depth 1 https://aur.archlinux.org/yay.git "$tmp/yay"
    (( DRY )) || ( cd "$tmp/yay" && makepkg -si --noconfirm )
    run rm -rf "$tmp"
  fi

  for set in base shell desktop nvidia; do
    step "packages: $set"
    install_list "$REPO/scripts/packages/$set.txt"
  done
fi

# ── zsh framework (not packaged; .zshrc sources these from $HOME) ─────────────
if want shell || want packages; then
  step "oh-my-zsh + powerlevel10k"
  if [[ -d $HOME/.oh-my-zsh ]]; then ok "~/.oh-my-zsh present"
  else run git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"; fi
  if [[ -d $HOME/powerlevel10k ]]; then ok "~/powerlevel10k present"
  else run git clone --depth 1 https://github.com/romkatv/powerlevel10k.git "$HOME/powerlevel10k"; fi
  if [[ $SHELL == */zsh ]]; then ok "login shell is already zsh"
  else run chsh -s /usr/bin/zsh; fi
fi

# ── fonts + icon themes that are deliberately not vendored ───────────────────
if want assets || want packages; then
  step "fonts and icon themes"
  run "$REPO/scripts/install-assets.sh"
fi

# ── dotfiles ─────────────────────────────────────────────────────────────────
if want link; then
  step "dotfiles"
  if (( DRY )); then run "$REPO/bin/dots" link --dry-run; else run "$REPO/bin/dots" link; fi
fi

# ── services ─────────────────────────────────────────────────────────────────
if want services; then
  step "system services"
  for svc in NetworkManager bluetooth auto-cpufreq nvidia-persistenced reflector.timer; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then ok "$svc already enabled"
    else run sudo systemctl enable --now "$svc"; fi
  done
  step "user services"
  for svc in pipewire.socket pipewire-pulse.socket wireplumber; do
    if systemctl --user is-enabled --quiet "$svc" 2>/dev/null; then ok "$svc already enabled"
    else run systemctl --user enable --now "$svc"; fi
  done
fi

# ── /etc ──────────────────────────────────────────────────────────────────────
if want all; then
  step "system configuration (/etc)"
  echo "  These need root and a regeneration step, so bootstrap does NOT apply them."
  echo "  Review and apply them yourself:"
  echo "      $REPO/bin/dots diff  system"
  echo "      $REPO/bin/dots push  system"
  echo "      sudo grub-mkconfig -o /boot/grub/grub.cfg"
  echo "      sudo mkinitcpio -P"
fi

step "done"
echo "  Next: log out and back in on tty1 — .zprofile execs ~/.local/bin/start-wayfire."
echo "  Then check everything with:  $REPO/bin/dots doctor"
