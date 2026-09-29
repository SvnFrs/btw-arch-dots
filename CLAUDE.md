# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Personal Arch Linux + Wayfire dotfiles for one specific machine: an **Acer
Predator PT516-51s** (i7-11800H, hybrid Intel UHD + NVIDIA RTX 3060 Mobile,
hostname `GloriousArch`). No build system, no test suite, no application code.
"Correct" means the target daemon reloads without error and `bin/dots doctor`
passes — not that a compiler succeeds.

## The deployment model — read before editing any config

Paths map by their first component: `home/…` → `$HOME/…`, `system/…` → `/…`.
[`dots.conf`](dots.conf) assigns every tracked path one of three modes:

- **`link`** — `$HOME` symlinks *into* the repo. `~/.config/wayfire.ini` **is**
  `home/.config/wayfire.ini`. Edit either path; they are one file. These cannot
  drift, so `git status` is their report. Most things are here.
- **`copy`** — the application rewrites the file itself (nwg-look regenerates
  four GTK files per Apply; fcitx5 rewrites `profile`; VS Code / Zed / btop
  persist UI state). Snapshots, watched for drift.
- **`root`** — `/etc`. Copied, `sudo` on push, needs a regeneration step after.

**Consequence:** editing a `link` file changes the live system immediately. There
is no deploy step and no "apply" to forget. Editing a `copy` file changes
nothing until `dots push`.

Never re-add the old copy-both-ways pattern — `link` exists precisely so drift
cannot happen.

## Commands

```bash
./bin/dots status            # drift report; exit 1 if anything drifted
./bin/dots doctor            # session, compositor, GPU, audio, theming checks
./bin/dots diff [path]       # what actually differs
./bin/dots pull|push [path]  # copy/root entries only; link entries have nothing to move
./bin/dots link              # (re)create symlinks; backs up whatever is there
./bin/dots adopt <path>      # bring a new live file into repo + manifest
./bin/dots scan              # live configs not tracked yet

./scripts/bootstrap.sh [--dry-run] [packages|link|services|assets]
./scripts/build-wayfire.sh [--debug|--release]
./scripts/install-assets.sh
./scripts/gen-keybindings.sh [--check]    # docs/keybindings.md is GENERATED
./scripts/hooks/install.sh                # pre-commit: drift + stale docs + shell syntax
```

Validation after touching a config (run against the live path):

```bash
kitty --config ~/.config/kitty/kitty.conf --debug-config
makoctl reload                                     # if mako is ever reinstated
sudo grub-mkconfig -o /boot/grub/grub.cfg          # after system/etc/default/grub
sudo mkinitcpio -P                                 # after mkinitcpio.conf or modprobe.d/
```

Wayfire watches `wayfire.ini` and re-reads it on save, so option and keybinding
changes apply live. `[autostart]` entries only run at session start.

The watch is on the file's **inode**. A save that writes a new file and renames it
over the old one (the Edit/Write tools do this) kills live reload for the rest of
the session, silently. So does `git switch`/`checkout`/`merge` whenever
`wayfire.ini` differs between the commits. An unchanged inode number proves
nothing, because filesystems reuse freed numbers. Confirm a change landed with python-wayfire's
`WayfireSocket().get_option_value("section/option")`. Re-arm the watch by
atomically replacing the symlink:
`ln -s "$PWD/home/.config/wayfire.ini" ~/.config/.wf && mv -T ~/.config/.wf ~/.config/wayfire.ini`.

## Architecture

### Wayfire is built from source — this is load-bearing

`/usr/local/bin/wayfire`, built from `github.com/SvnFrs/wayfire` (a personal
fork) with wlroots as a meson subproject (`use_system_wlroots=disabled`).
`wayfire.ini` enables **`spread-overview`, which exists only in that fork** — the
packaged compositor cannot load this config.

The `wayfire`, `wayfire-plugins-extra`, `wf-config` and `wlroots0.19` packages
are *also* installed and entirely unused; the running process maps only
`/usr/local/lib/wayfire/*.so`. Do not "fix" the package lists by adding the
`wayfire` package back. See [`docs/wayfire-build.md`](docs/wayfire-build.md).

### `wayfire.ini` is the hub

It owns the whole session: `[autostart]` is the daemon set (fcitx5, awww,
swaync, polkit, keyring, kanshi, the IPC scripts), and `[command]` is every
keybinding. It does **not** own the output layout — kanshi does.

Two things that bite:

- **Outputs belong to kanshi** (`~/.config/kanshi/config`: profiles `code`,
  `train`, `laptop`). `<super>C` / `<super>A` run `kanshictl switch`.
  `[workarounds] use_external_output_configuration = true` stops a save of
  `wayfire.ini` from re-applying `[output:*]` over the active profile. The only
  output section is `HDMI-A-1` pinned off. **Never put `mode = off` on `eDP-1` or
  `DP-3`**: it is static, applies before kanshi starts, and undocked it means no
  picture. `dots doctor` fails on it.
- **`export FOO=bar` in `[autostart]` is a no-op** — each entry is its own
  process. Session env belongs in `~/.local/bin/start-wayfire`, which `.zprofile`
  execs on tty1. There is no display manager.

### Display topology is counter-intuitive

`eDP-1` (internal) **and `DP-3` (the external monitor) are both on the Intel
iGPU**; only `HDMI-A-1` is on the NVIDIA GPU. The compositor therefore runs on
Intel and the 3060 is an offload device (`prime-run`, or the `nvidia-run` alias).
**Do not add `GBM_BACKEND=nvidia-drm` / `WLR_DRM_DEVICES`** — they buy nothing
here and cost battery. Details in [`docs/hardware.md`](docs/hardware.md).

Root is on the **second** NVMe (`nvme1n1p2`); `nvme0n1` is Windows. Address it by
`UUID=`, never `/dev/nvme…`.

### swaync/actions.sh is the shared action entry point

Both the `wayfire.ini` keybindings and the notification-centre buttons call
`~/.config/swaync/actions.sh <verb>`. One place to fix, one log at
`~/.cache/swaync-actions.log`. Its comments record four fixed bugs (volume going
through ALSA under PipeWire, per-channel rounding drift, `wf-recorder -a` with a
space being silently ignored, `xdg-user-dir` returning `$HOME`). Read them before
changing volume or capture behaviour — those are all easy to reintroduce.

### Theming is duplicated by design

Catppuccin Mocha is hardcoded independently in kitty, rofi
(`catppuccin-mocha.rasi`), btop, `FZF_DEFAULT_OPTS` in `.zshrc`, wayfire's RGBA
tuples, the GTK settings, and `GRUB_THEME`. There is no shared color source;
changing the theme means touching all of them. `.zshrc` deliberately sources the
**macchiato** syntax-highlighting variant.

### Assets

`.gitignore` excludes JetBrains Mono Nerd, Catppuccin-SE and GoogleDot cursors —
`install-assets.sh` re-fetches them. The `Graphite-Recolored-*` recolors and the
`oreo_*` cursors are vendored because they are not re-downloadable. Never add
redistributable assets to git; extend `install-assets.sh` instead.

**This repo is public, so fonts do not live here.** Cartograph CF (the VS Code /
Zed editor font, commercial) and every other personal font live in the
**private** repo `SvnFrs/cartograph-fonts`, checked out at
`~/Documents/Projects/cartograph-fonts`. It has its own CLI, `fonts` (on PATH
via `~/.local/bin/fonts`): `fonts add <zip|dir|file> [--nerd]`, `fonts patch`,
`fonts install`, `fonts doctor`. It links `~/.local/share/fonts/<slug>` into
that repo. `install-assets.sh` clones it and runs `fonts install`, and
`dots doctor` checks that `CartographCF Nerd Font` resolves. Never commit a font
file to this repo.

## Conventions

- **Never vendor distro defaults.** The old repo tracked 25 PipeWire files that
  were a stale copy of the 0.3.79 defaults, plus ranger's unmodified `rc.conf`.
  Track `*.conf.d/` drop-ins and genuinely modified files only.
- **`~/.config/ipc-scripts/*.py` use the `python-wayfire` package**
  (`from wayfire import WayfireSocket`). Wayfire ships IPC in-tree now. A
  vendored `wayfire_socket.py` used to sit beside them — it is deleted, and must
  not come back. `dots doctor` checks the module imports.
- **`docs/keybindings.md` is generated.** Rebind in `wayfire.ini`, then run
  `./scripts/gen-keybindings.sh`. The pre-commit hook enforces this.
- **Package lists are verified, not aspirational.** Everything in
  `scripts/packages/*.txt` is referenced by a tracked config or derived from the
  build tree's own meson dependency list.
- `~/.gitconfig` is deliberately untracked (work credential helpers, work email).
  Only `~/.config/git/ignore` is tracked.
- There is no screen locker. swaylock was removed on purpose because it was
  unused, so don't add it back as a "missing" dependency.
