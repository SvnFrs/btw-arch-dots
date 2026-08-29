# ════════════════════════════════════════════════════════════════════
#  ~/.zshrc · thai@aleatoire
# ════════════════════════════════════════════════════════════════════

# ── Powerlevel10k instant prompt — keep at the very top ─────────────
# Anything needing console input (passwords, y/n) must go ABOVE this block.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ── History ─────────────────────────────────────────────────────────
HISTFILE=~/.histfile
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY
bindkey -e

# ── Environment ─────────────────────────────────────────────────────
export EDITOR=nvim
export RANGER_LOAD_DEFAULT_RC=false
export ANDROID_HOME="$HOME/Android/Sdk"
# kitty exports TERM=xterm-kitty itself (best for its graphics + features).
# Pinning xterm-256color trades that for broad SSH/tmux compatibility —
# delete this line if you'd rather have native kitty behaviour.
export TERM=xterm-256color

# PATH — bun first; go bin + glassfish appended (no subprocess at startup)
export PATH="$HOME/.bun/bin:$PATH"
export PATH="$PATH:${GOPATH:-$HOME/go}/bin:/opt/glassfish/bin"
export PATH="$HOME/.cargo/bin:$PATH"

# fzf — Catppuccin Mocha
export FZF_DEFAULT_OPTS=" \
--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
--color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
--color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8"

# Secrets (GitHub PAT, …) — kept OUT of this file. .gitignore ~/.config/zsh/.
[[ -f ~/.config/zsh/secrets.zsh ]] && source ~/.config/zsh/secrets.zsh

# ── Oh My Zsh ───────────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""                       # prompt comes from Powerlevel10k (below)
plugins=(
  colored-man-pages
  encode64
  extract
  frontend-search
  genpass
  git
  history
  web-search
  zsh-interactive-cd
)
source "$ZSH/oh-my-zsh.sh"

# ── Aliases ─────────────────────────────────────────────────────────
alias cd="z"                       # zoxide
alias ls="eza"
alias zed="zeditor"
alias btw="fastfetch"              # neofetch is archived — fastfetch, btw
alias code="code --ozone-platform=wayland"
alias nvidia-run="__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia"
alias bitwarden="cat ~/Documents/Secrets/bitwarden | wl-copy"

# ── thefuck — lazy (loads on first `fuck`; saves ~200ms at startup) ──
fuck() { unfunction fuck; eval "$(thefuck --alias)"; fuck "$@"; }

# ── nvm — lazy (loads on first node/npm/npx/nvm; you mostly use bun) ─
if [[ -f /usr/share/nvm/init-nvm.sh ]]; then
  _load_nvm() { unfunction nvm node npm npx 2>/dev/null; source /usr/share/nvm/init-nvm.sh; }
  nvm()  { _load_nvm; nvm  "$@"; }
  node() { _load_nvm; node "$@"; }
  npm()  { _load_nvm; npm  "$@"; }
  npx()  { _load_nvm; npx  "$@"; }
fi

# ── Powerlevel10k theme ─────────────────────────────────────────────
source ~/powerlevel10k/powerlevel10k.zsh-theme
[[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh   # run `p10k configure` to edit

# ── zsh-syntax-highlighting — sourced near the end (after widgets) ──
source ~/.zsh/themes/catppuccin_macchiato-zsh-syntax-highlighting.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

export _ZO_DOCTOR=0

# ── zoxide — init LAST (silences the doctor warning) ────────────────
eval "$(zoxide init zsh)"

# ── gstack: use system Chromium instead of Playwright's bundled build ──
# Playwright ships an unsupported Ubuntu fallback Chromium on Arch whose
# chrome-headless-shell download hangs. The patched browse engine honors
# this var (headless + headed). See browse/src/browser-manager.ts.
export GSTACK_CHROMIUM_PATH=/usr/bin/chromium
