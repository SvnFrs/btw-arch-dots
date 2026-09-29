# How the session is wired

No display manager. `.zprofile` starts everything from tty1.

```
tty1 login
  └─ ~/.zprofile          only when $DISPLAY is empty and tty == /dev/tty1
       └─ exec ~/.local/bin/start-wayfire
            ├─ exports XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE, OZONE_PLATFORM,
            │          GTK_IM_MODULE, QT_IM_MODULE, XMODIFIERS, INPUT_METHOD
            └─ exec wayfire            -> /usr/local/bin/wayfire (source build)
                 └─ wayfire.ini [autostart]
```

## Why the wrapper exists

`[autostart]` entries used to read:

```ini
1_env = export OZONE_PLATFORM=wayland
```

That is a no-op. Wayfire spawns every autostart entry as its own process; the
`export` sets a variable in a shell that exits immediately, and nothing else
ever sees it. Environment for the session has to be set *before* Wayfire starts,
which is what `start-wayfire` does. Those lines are commented out in
`wayfire.ini` with the explanation kept in place.

To confirm the variables really reached the compositor:

```sh
grep -z OZONE_PLATFORM /proc/$(pgrep -x wayfire | head -1)/environ | tr '\0' '\n'
```

## What `[autostart]` launches

| entry | what it does |
|---|---|
| `0_env` | pushes `WAYLAND_DISPLAY` / `XDG_CURRENT_DESKTOP` into the dbus activation environment |
| `fcitx5` | input method daemon |
| `blur_on_inactive` | `~/.config/ipc-scripts/inactive-alpha.py` — dims unfocused windows over Wayfire IPC |
| `awww` | wallpaper daemon, then sets the wallpaper once the daemon answers |
| `screen_sharing_fix` | `~/.config/wayfire/ss-fix.sh` — restarts `xdg-desktop-portal` with the right env so screencast works |
| `polkit-agent` | authentication prompts |
| `keyring` | gnome-keyring (secrets, ssh, pkcs11) |
| `notifications` | `swaync` |
| `session_target` | starts `graphical-session.target` so user units can hang off it |

Both IPC scripts talk to the compositor through the **`python-wayfire`**
package (`from wayfire import WayfireSocket`). Wayfire ships IPC in-tree now, so
the old vendored `wayfire_socket.py` that used to sit beside them is gone — do
not reintroduce it. `dots doctor` verifies the module imports and that every
script referenced from `wayfire.ini` exists.

## swaync does the heavy lifting

`~/.config/swaync/actions.sh` is a single entry point shared by both the
keybindings in `wayfire.ini` and the buttons in the notification centre:

```
actions.sh <snip|shot|rec|rec-area|cal|vol-up|vol-down|vol-mute|mic-mute>
```

One place to fix, one log at `~/.cache/swaync-actions.log`, and `rec`/`rec-area`
are genuine toggles rather than commands that spawn a second recording.

Four bugs were found and fixed there, and the reasoning is preserved in the
script's comments:

- **Volume went through the wrong layer.** `amixer set Master` talks straight to
  ALSA, *below* PipeWire, while swaync reads volume through libpulse. The slider
  and the keys disagreed. Now everything goes through `pactl`.
- **Volume channels drifted apart.** Relative steps (`5%+`) add a delta to each
  channel and round each one separately, so left and right diverge and never
  re-converge. `actions.sh` reads the current value and writes an *absolute*
  one with no channel prefix, which applies the same number to every channel.
- **Recordings captured the microphone.** `wf-recorder -a DEVICE` with a space
  is silently ignored — the argument to `-a` is optional, so it must be written
  `--audio=DEVICE`. It was recording the mic while the log said otherwise.
- **Files landed in the wrong place.** `xdg-user-dir PICTURES` returns `$HOME`
  when `~/.config/user-dirs.dirs` does not define it, so screenshots went to
  `~/Screenshots`. `actions.sh` detects that and falls back to `~/Pictures/...`.

## Displays

kanshi owns the output layout. It is autostarted from `wayfire.ini`, and its
profiles live in `~/.config/kanshi/config`:

| profile  | when                          | what is on        |
|----------|-------------------------------|-------------------|
| `code`   | G5 plugged in (auto)          | G5 only           |
| `train`  | G5 plugged in, `<super>A`     | laptop panel only |
| `laptop` | G5 unplugged (auto)           | laptop panel      |

`<super>C` returns to `code`. Plugging or unplugging the G5 picks the matching
profile by itself. `kanshictl status` shows the active one. Both outputs are on
the Intel iGPU; the G5's second cable (`HDMI-A-1`, on NVIDIA) stays off in every
profile. See [hardware.md](hardware.md).

`[workarounds] use_external_output_configuration = true` in `wayfire.ini` is what
makes this hold. Without it, every save of `wayfire.ini` re-applies `[output:*]`
and undoes the active profile.

Do not put `mode = off` on `eDP-1` or `DP-3` in `wayfire.ini`. It is static and
applies before kanshi starts, so undocked, or with kanshi not running, it
leaves no picture. `dots doctor` fails on it.

`wlsunset` is deliberately not autostarted: the swaync button owns it, and two
owners means the button reports the state of an instance it did not start.
