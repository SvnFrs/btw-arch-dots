# btw-arch-dots

Arch Linux + [Wayfire](https://wayfiredotorg.github.io/) dotfiles for an
**Acer Predator PT516-51s** — i7-11800H, hybrid Intel UHD + NVIDIA RTX 3060
Mobile, Catppuccin Mocha throughout.

Kept since 2023. Restructured in 2026 for the NVIDIA laptop, with a deployment
model that makes "which file in the repo is outdated?" answerable in one command.

```
dots status      # what is deployed, what drifted, what needs attention
dots doctor      # is the session, GPU, audio and theming wiring actually sane
```

---

## How deployment works

Two mechanisms, chosen per file in [`dots.conf`](dots.conf):

**`link`** — `$HOME` symlinks *into* this repo. Editing `~/.config/wayfire.ini`
edits `home/.config/wayfire.ini`, because they are the same file. These entries
**cannot drift**; `git status` is their report. Everything you hand-edit is here.

**`copy`** — a snapshot of a file its own application rewrites. nwg-look
regenerates four GTK files on every Apply; fcitx5 rewrites `profile` on every
input-method switch; VS Code, Zed and btop all persist UI state back into their
config. A symlink there either gets clobbered or lets the app commit noise into
git, so these are copied and *watched*. They are the only things that can go
stale, and they are exactly what `dots status` diffs for you.

**`root`** — `/etc` files. Copied, `sudo` on push, and push tells you which
regeneration command to run afterwards.

```
$ dots status
  DRIFT     copy   home/.config/gtk-3.0/settings.ini   live is newer (dots pull …)
  UNLINKED  link   home/.config/kitty/kitty.conf       real file — run: dots link

  52 in sync · 1 drifted · 1 need attention
```

Exit status is non-zero when anything drifted, so it drops into a prompt or a
pre-commit hook:

```sh
dots status >/dev/null || echo "dotfiles drifted"
```

---

## Layout

```
btw-arch-dots/
├── dots.conf              the manifest: one line per tracked path
├── bin/dots               deploy + drift tracking
├── home/                  → $HOME
├── system/                → /            (needs root)
├── scripts/
│   ├── bootstrap.sh       fresh machine → this desktop
│   ├── build-wayfire.sh   compile the compositor this config needs
│   ├── install-assets.sh  fonts + icon themes that are not vendored
│   ├── gen-keybindings.sh regenerates docs/keybindings.md from wayfire.ini
│   ├── hooks/             versioned git hooks (install.sh points git at them)
│   └── packages/          base · shell · desktop · nvidia · wayfire-build
└── docs/
    ├── installation.md    installing Arch itself, on this hardware
    ├── hardware.md        GPU topology, outputs, power — read before touching displays
    ├── wayfire-build.md   why the compositor is built from source, and how
    ├── session.md         how the Wayfire session is wired together
    └── keybindings.md     generated — do not hand-edit
```

Optional, recommended:

```sh
./scripts/hooks/install.sh   # pre-commit: blocks drift, stale keybinding docs, bad shell syntax
```

---

## Setup on a fresh machine

Install Arch first — [`docs/installation.md`](docs/installation.md) covers the
disk layout and GRUB setup this machine actually uses. Then:

```sh
git clone https://github.com/SvnFrs/btw-arch-dots.git ~/dots
cd ~/dots
./scripts/bootstrap.sh          # packages, yay, oh-my-zsh, fonts, symlinks, services
./scripts/build-wayfire.sh      # the compositor — see below, this is not optional
./bin/dots doctor               # verify
```

> **Wayfire is built from source here, not installed from a package.**
> `wayfire.ini` enables `spread-overview`, which exists only in
> [`SvnFrs/wayfire`](https://github.com/SvnFrs/wayfire). The packaged compositor
> cannot load this config. `scripts/build-wayfire.sh` reproduces the build into
> `/usr/local`, wlroots included as a meson subproject.
> Details in [`docs/wayfire-build.md`](docs/wayfire-build.md).

`bootstrap.sh` is idempotent and takes stages (`packages`, `link`, `services`,
`assets`) plus `--dry-run`. It never overwrites a config — `dots link` moves
anything already in place into `.backups/<timestamp>/` first.

It deliberately does **not** touch `/etc`. Review and apply that yourself:

```sh
dots diff system
dots push system
sudo grub-mkconfig -o /boot/grub/grub.cfg    # if grub changed
sudo mkinitcpio -P                           # if mkinitcpio.conf or modprobe.d changed
```

---

## Daily use

| I want to… | run |
|---|---|
| see what is out of date | `dots status` |
| see what actually differs | `dots diff` |
| accept the live version | `dots pull [path]` |
| put the repo version back on the system | `dots push [path]` |
| track a new config file | `dots adopt ~/.config/foo/bar.conf` |
| find configs I forgot to track | `dots scan` |
| check the session is wired correctly | `dots doctor` |

For `link` entries there is nothing to pull or push — edit the file, then commit.

---

## What is deliberately not here

| | why |
|---|---|
| JetBrains Mono Nerd, Catppuccin-SE icons, GoogleDot cursors | freely re-downloadable — `scripts/install-assets.sh` |
| `~/.config/pipewire/*.conf` | vendoring the distro defaults means silently running a stale copy after every PipeWire update. Only `*.conf.d/` drop-ins are tracked |
| ranger `rc.conf`, `commands.py`, `commands_full.py` | byte-identical to the shipped defaults |
| `~/.gitconfig` | carries work credential helpers and a work email. `~/.config/git/ignore` is tracked; identity stays machine-local |
| systemd-boot config | this machine boots GRUB. The old `boot/loader/` entry pointed at the wrong disk entirely |
| the `wayfire` package | the compositor is a source build in `/usr/local` — see [`docs/wayfire-build.md`](docs/wayfire-build.md) |

Cartograph CF (commercial), the `Graphite-Recolored-*` recolors and the `oreo_*`
cursors **are** vendored — they are not re-downloadable.

---

## Hardware notes

Read [`docs/hardware.md`](docs/hardware.md) before changing anything to do with
displays. The short version, because it is counter-intuitive:

- `eDP-1` (internal panel) and **`DP-3` (the external monitor) are both on the
  Intel iGPU.** Only `HDMI-A-1` is wired to the NVIDIA GPU.
- So the compositor runs on Intel, and the 3060 is an offload device
  (`prime-run`, or the `nvidia-run` alias). This is why the session is stable
  without any `GBM_BACKEND=nvidia-drm` hacks — do not add them.
- `mode = off` in `wayfire.ini` is static and applies the moment the file is
  saved. Setting it on the output you are currently using, while the other is
  off, leaves you with no picture. `dots doctor` checks for exactly that.

---

## License

MIT — see [LICENSE](LICENSE).
