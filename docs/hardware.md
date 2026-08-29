# Hardware

**Acer Predator PT516-51s** · hostname `GloriousArch`

| | |
|---|---|
| CPU | Intel Core i7-11800H (Tiger Lake-H, 8C/16T) |
| iGPU | Intel UHD Graphics — `8086:9a60`, `i915` |
| dGPU | NVIDIA GeForce RTX 3060 Mobile / Max-Q (GA106M) — `10de:2520`, `nvidia-open-dkms` |
| RAM | 31 GiB, **no swap and no zram** |
| Panel | 2560×1600 @ 165 Hz internal |
| Kernel | `linux-zen` |
| Boot | GRUB (UEFI), Secure Boot disabled |

## Disks — read this before touching bootloader config

There are **two** NVMe drives, and Linux is on the **second** one.

```
nvme0n1   953.9G   Windows
  ├─p1      200M   vfat    (Windows ESP)
  ├─p2       16M           (Microsoft reserved)
  ├─p3    952.8G   ntfs
  └─p4      845M   ntfs    (recovery)

nvme1n1   953.9G   Linux
  ├─p1      500M   vfat    ->  /boot/efi
  └─p2    953.4G   ext4    ->  /            UUID=7b03567b-a625-4a17-865b-3a029ae3ccb1
```

The pre-2026 version of this repo shipped a systemd-boot entry with
`root=/dev/nvme0n1p2` hardcoded. On this machine that is the 16 MB Microsoft
reserved partition on the *Windows* disk. It has been deleted — this machine
boots GRUB, and `system/etc/default/grub` is the only bootloader config here.

Always address the root filesystem by `UUID=`, never `/dev/nvme…`: NVMe
enumeration order is not guaranteed across boots.

## GPU topology — the counter-intuitive part

Connectors do not map to GPUs the way you would guess:

```
card1  nvidia   eDP-2 (disconnected — MUX path to the internal panel, unused)
                HDMI-A-1

card2  i915     eDP-1  <- the internal 2560x1600 panel, currently the only active output
                DP-1  DP-2  DP-3  DP-4
```

**`DP-3` — the external monitor `wayfire.ini` switches to with `<super>C` — is
on the Intel iGPU, not the NVIDIA GPU.** Only `HDMI-A-1` is wired to the 3060.

Consequences:

- Wayfire runs on Intel. That is why this session is stable without
  `GBM_BACKEND=nvidia-drm`, `WLR_DRM_DEVICES` or the other NVIDIA-Wayland
  workarounds. **Do not add them** — forcing the compositor onto the dGPU here
  costs battery and buys nothing, since the panel hangs off Intel anyway.
- The 3060 is an offload device. Run things on it explicitly:
  ```sh
  prime-run <app>        # from nvidia-prime
  nvidia-run <app>       # the .zshrc alias, same env vars by hand
  ```
- `WLR_NO_HARDWARE_CURSORS=1` in `.zprofile` is a legacy workaround for old
  NVIDIA drivers. On driver 610 with the compositor on Intel it is inert. It is
  left in place because it is harmless and costs nothing to keep.

## Kernel parameters

From `system/etc/default/grub`:

```
loglevel=3 quiet
mitigations=off nowatchdog nmi_watchdog=0     # performance over hardening — deliberate
nvidia_drm.modeset=1 nvidia_drm.fbdev=1       # required for Wayland on NVIDIA
i915.enable_guc=3                             # GuC + HuC submission (media offload)
i915.enable_fbc=1                             # framebuffer compression, saves power
acpi_backlight=native                         # brightnessctl only works with this
```

`mitigations=off` disables CPU speculative-execution mitigations. It is a real
security trade-off, taken knowingly on a personal laptop.

## NVIDIA module options

All in `system/etc/modprobe.d/nvidia.conf`. This used to be spread over three
files (`nvidia.conf`, `nvidia-pm.conf`, `nvidia-power.conf`) with
`NVreg_DynamicPowerManagement` set in two of them — consolidated into one file.

`NVreg_DynamicPowerManagement=0x02` is the single biggest battery win here: it
lets the dGPU power down completely when idle.

**EnvyControl rewrites `/etc/modprobe.d/nvidia.conf`** when you switch GPU modes.
After `envycontrol -s <mode>`, run `dots status` — it will show the file as
drifted, and `dots diff system` will show exactly what EnvyControl changed.

## initramfs

`MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)` early-loads the NVIDIA
modules, which `nvidia_drm.modeset=1` needs.

`/etc/mkinitcpio.conf` shipped with **two `HOOKS=` lines**. mkinitcpio sources
the file as shell, so the last assignment silently won and the first never did
anything. Fixed in `system/etc/mkinitcpio.conf`; `dots doctor` checks for a
recurrence. The live one is:

```
HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block filesystems fsck)
```

After changing `mkinitcpio.conf` or anything in `modprobe.d/`: `sudo mkinitcpio -P`.

## Power

- `auto-cpufreq.service` handles frequency scaling.
- `acer-wmi-battery-dkms` exposes the Predator charge limit under `/sys`.
- No swap and no zram with 31 GiB RAM. Fine for normal use, but **hibernation
  cannot work** without a swap device sized for RAM.
