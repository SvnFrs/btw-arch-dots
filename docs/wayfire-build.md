# Wayfire is built from source here

**The packaged Wayfire will not run this configuration.** `wayfire.ini` enables
`spread-overview`, a plugin that exists only in the personal fork below. Install
the `wayfire` package and the compositor starts without it.

## What is actually running

```
binary   /usr/local/bin/wayfire
version  0.11.0  (master, built against wlroots-0.20.2)
plugins  /usr/local/lib/wayfire/          71 .so files
source   https://github.com/SvnFrs/wayfire.git   branch master
tree     ~/Documents/Projects/wayfire
```

`wlroots` is **not** a system dependency. The build sets
`use_system_wlroots=disabled`, so wlroots comes from the meson subproject in
`subprojects/wlroots` and installs as `/usr/local/lib/libwlroots-0.20.so`.
Wayfire master tracks wlroots much more closely than the repos do; pinning to
the bundled copy keeps the two in step and makes the build independent of
whichever `wlroots0.xx` package happens to be current.

Other meson subprojects: `wf-config`, `wf-json`, `wf-touch`, `wf-utils`,
`wlroots-vkfx`.

## Rebuilding

```sh
./scripts/build-wayfire.sh              # release build, installs to /usr/local
./scripts/build-wayfire.sh --debug      # matches the build currently installed
./scripts/build-wayfire.sh --no-install # compile only
```

It installs the build dependencies from `scripts/packages/wayfire-build.txt`
(derived from the build tree's own meson dependency list), fetches or updates
the checkout, configures with the options below, compiles, installs, and then
verifies that every plugin named in `wayfire.ini` has a matching `.so`.

```
--prefix=/usr/local  --libdir=lib
-Duse_system_wlroots=disabled
-Denable_gles32=true
-Denable_openmp=true
-Dtests=enabled
```

Log out and back in to pick up a new build.

## Two known snags

**1. The packaged Wayfire is also installed.**

```
wayfire 0.11.0-1              /usr/lib/wayfire      73 plugins   (unused)
wayfire-plugins-extra 0.10.0-2                                   (unused)
wf-config 0.11.0-1                                               (unused)
wlroots0.19 0.19.3-1                                             (unused)
```

Nothing loads any of it — the running process maps only `/usr/local/lib/wayfire/*.so`.
It is inert *today*, but it is a trap: `/usr/local/bin` precedes `/usr/bin` by
convention, not by guarantee. If that ever changes you launch the packaged
compositor, which has no `spread-overview`, and the failure looks like a config
error rather than the wrong binary.

Either remove them:

```sh
sudo pacman -Rns wayfire wayfire-plugins-extra wf-config wlroots0.19
```

or keep them knowingly. `dots doctor` reports the situation either way. They are
kept installed at the moment; removing them is the tidier end state but is left
as your call since `wayfire-plugins-extra` depends on `wayfire` and pacman will
want to take both.

**2. The installed build is `buildtype=debug`, `optimization=0`.**

That is an unoptimised compositor running as your daily driver, with
`print_trace` on as well. Fine for bisecting a bug, needlessly slow the rest of
the time. `./scripts/build-wayfire.sh` defaults to `--release` for that reason;
pass `--debug` when you actually want to debug. `dots doctor` flags it.

## The fork

`~/Documents/Projects/wayfire` tracks `SvnFrs/wayfire`, which carries the
`spread-overview` work (see `specs/001-spread-overview/` in that tree).
`~/Documents/Projects/wayfire-plugins-extra` tracks upstream `WayfireWM`, and
`~/Documents/Clones/wayfire-plugins-extra` is a second checkout of a personal
fork. Both plugins-extra trees are configured to install into `/usr/local` — if
you build both, whichever ran `ninja install` last wins for any plugin they
share. Prefer building only one.

Syncing the fork with upstream is documented in the fork itself
(`docs: upstream sync runbook`, commit 878ee54).
