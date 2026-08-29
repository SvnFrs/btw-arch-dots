# Installing Arch on this machine

This reproduces the install that is actually running: **GRUB**, UEFI, ext4 root
on the second NVMe, dual-booting Windows on the first. Read
[`hardware.md`](hardware.md) for the disk layout before you start.

The previous version of this file described a `scripts/install-explained.sh`
and a `scripts/install-min.sh`. Neither ever existed in the repo. This document
is the procedure — there is no magic script for partitioning someone's disks,
and pretending otherwise is how people lose data.

> **Destructive.** Steps 2–3 erase a partition. Confirm every device path
> against `lsblk` on *your* machine. `nvme1n1` here is the Linux disk;
> `nvme0n1` is Windows and must not be touched.

## 1. Boot the ISO and get online

```sh
iwctl
# in the prompt:
station wlan0 connect "YOUR_SSID"
exit

ping -c3 archlinux.org
timedatectl set-ntp true
```

## 2. Partition

```sh
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL      # identify the Linux disk first
cfdisk /dev/nvme1n1
```

GPT, two partitions:

| # | size | type | becomes |
|---|---|---|---|
| 1 | 512 M | EFI System | `/boot/efi` |
| 2 | rest | Linux filesystem | `/` |

No swap partition is used here (31 GiB RAM). Add one sized ≥ RAM if you want
hibernation.

## 3. Format and mount

```sh
mkfs.fat -F32 /dev/nvme1n1p1
mkfs.ext4     /dev/nvme1n1p2

mount /dev/nvme1n1p2 /mnt
mount --mkdir /dev/nvme1n1p1 /mnt/boot/efi
```

## 4. Install the base system

```sh
reflector --country Vietnam,Singapore --age 12 --protocol https \
          --sort rate --save /etc/pacman.d/mirrorlist

pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    sof-firmware intel-ucode grub efibootmgr os-prober ntfs-3g \
    networkmanager neovim git zsh sudo

genfstab -U /mnt >> /mnt/etc/fstab      # -U: UUIDs, not /dev paths
```

`genfstab -U`, not `genfstab`. NVMe enumeration order can change between boots
and a `/dev`-based fstab will eventually fail to mount.

## 5. Configure inside the chroot

```sh
arch-chroot /mnt

ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo 'KEYMAP=us'        > /etc/vconsole.conf
echo 'GloriousArch'     > /etc/hostname

passwd                                          # root
useradd -m -G wheel -s /usr/bin/zsh thai
passwd thai
EDITOR=nvim visudo                              # uncomment: %wheel ALL=(ALL:ALL) ALL

systemctl enable NetworkManager
```

## 6. GRUB

```sh
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch

# so the Windows install on nvme0n1 shows up in the menu
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg
```

Check the output mentions both Arch and Windows. If Windows is missing, confirm
`os-prober` and `ntfs-3g` are installed and that the Windows ESP is readable.

## 7. Reboot

```sh
exit
umount -R /mnt
reboot
```

## 8. Everything else

Log in as your user, then:

```sh
sudo pacman -S --needed git
git clone https://github.com/SvnFrs/btw-arch-dots.git ~/dots
cd ~/dots
./scripts/bootstrap.sh
./bin/dots doctor
```

`bootstrap.sh` installs yay, the four package sets (including the NVIDIA stack),
oh-my-zsh and powerlevel10k, the non-vendored fonts and icon themes, deploys the
dotfiles, and enables the services.

Then apply the `/etc` side, which bootstrap deliberately leaves to you:

```sh
./bin/dots diff system
./bin/dots push system
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo mkinitcpio -P
reboot
```

Log in on **tty1** — `.zprofile` execs `~/.local/bin/start-wayfire` there. There
is no display manager.

## Troubleshooting

**Black screen after login.** `.zprofile` only starts Wayfire on tty1. On any
other VT you get a shell. Check `~/.local/bin/start-wayfire` is executable.

**Both monitors dark.** `mode = off` in `wayfire.ini` is static and applies on
save. Switch VT (`Ctrl+Alt+F2`), log in, and fix the file — `dots doctor` flags
this configuration before it bites.

**No NVIDIA after a kernel update.** DKMS rebuild failed. `sudo dkms status`,
then `sudo mkinitcpio -P`. Confirm `linux-zen-headers` matches `linux-zen`.

**Brightness keys dead.** `acpi_backlight=native` must be on the kernel cmdline.

**No sound from the speakers.** `sof-firmware` is required on this chassis.
