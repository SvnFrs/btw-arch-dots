#!/usr/bin/env bash
# scripts/install-explained.sh
# Purpose: reproducible Arch install that supports GRUB or systemd-boot
# Reuses this repo's boot/loader templates and patches machine-specific bits.
# Run from the repo root so it can find ./boot/loader/*

set -euo pipefail

### 0) INPUTS (you already partitioned with cfdisk/parted)
# We ask for device nodes instead of guessing. This avoids nuking the wrong disk.
read -rp "EFI partition (e.g. /dev/nvme0n1p1 or /dev/sda1): " EFI
read -rp "ROOT partition (e.g. /dev/nvme0n1p3 or /dev/sda3): " ROOT
read -rp "SWAP partition (Enter to skip): " SWAP || true

### 1) BASIC SETTINGS
TZ="Asia/Ho_Chi_Minh"    # your local timezone
LOCALE="en_US.UTF-8"     # default locale
KEYMAP="us"              # console keymap
HOSTNAME="${HOSTNAME:-ArchBTW}"  # change if you want

REPO_ROOT="$(pwd)"
REPO_LOADER="${REPO_ROOT}/boot/loader"

echo "==> Formatting EFI (${EFI}) as FAT32 and ROOT (${ROOT}) as ext4"
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"

echo "==> Mounting ROOT to /mnt and EFI to /mnt/boot/efi"
mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

if [[ -n "${SWAP:-}" ]]; then
  echo "==> Creating and enabling SWAP on ${SWAP}"
  mkswap "$SWAP"
  swapon "$SWAP"
fi

### 2) BASE SYSTEM
# Keep things lean; desktop packages can come later. We omit bootloader packages here
# because we support two different ones and will install the chosen one later.
echo "==> Installing base packages"
pacstrap -K /mnt base linux linux-firmware sof-firmware base-devel neovim git networkmanager

### 3) FSTAB
# -U makes mounts stable across device renames by using UUIDs.
echo "==> Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab
tail -n +1 /mnt/etc/fstab

### 4) CHROOT CONFIG
# Timezone, clock, locale, keymap, hostname, NetworkManager, CPU microcode
echo "==> Configuring system in chroot"
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

# Enable locale
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# Networking
systemctl enable NetworkManager

# CPU microcode (detect by vendor)
VENDOR=\$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \\t]+/, "", \$2); print \$2}')
UCODE=amd-ucode; [[ "\$VENDOR" == "GenuineIntel" ]] && UCODE=intel-ucode
pacman --noconfirm -S "\$UCODE"
CHROOT

### 5) BOOTLOADER
# You can choose to:
#   A) systemd-boot: we install bootctl, copy your repo's ./boot/loader, then patch PARTUUID/ucode/kernel
#   B) GRUB: install grub+efibootmgr+os-prober and generate grub.cfg
echo
echo "Choose bootloader:"
select BOOT in "systemd-boot (use repo boot/loader and patch it)" "GRUB (UEFI)"; do
  case "$BOOT" in
    "systemd-boot (use repo boot/loader and patch it)")
      echo "==> Installing systemd-boot"
      arch-chroot /mnt bootctl install

      if [[ -d "${REPO_LOADER}" ]]; then
        echo "==> Copying repo boot/loader into target"
        if command -v rsync >/dev/null 2>&1; then
          rsync -a --delete "${REPO_LOADER}/" /mnt/boot/loader/
        else
          mkdir -p /mnt/boot/loader
          (cd "${REPO_LOADER}" && tar cf - .) | (cd /mnt/boot/loader && tar xf -)
        fi
      else
        echo "==> Repo boot/loader missing; creating minimal loader files"
        mkdir -p /mnt/boot/loader/entries
        cat >/mnt/boot/loader/loader.conf <<EOF
default  arch
timeout  3
console-mode auto
editor   no
EOF
        cat >/mnt/boot/loader/entries/arch.conf <<'EOF'
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=PATCHME rw quiet loglevel=3 nowatchdog
EOF
      fi

      # Patch entries
      ROOT_REAL="$(readlink -f "$ROOT")"
      PARTUUID="$(blkid -s PARTUUID -o value "$ROOT_REAL")"

      if arch-chroot /mnt pacman -Q amd-ucode &>/dev/null; then
        UCODE_IMG="/amd-ucode.img"
      else
        UCODE_IMG="/intel-ucode.img"
      fi

      if arch-chroot /mnt bash -lc '[[ -f /boot/vmlinuz-linux-zen ]]'; then
        KERNEL="/vmlinuz-linux-zen"
        INITRD2="/initramfs-linux-zen.img"
      else
        KERNEL="/vmlinuz-linux"
        INITRD2="/initramfs-linux.img"
      fi

      for entry in /mnt/boot/loader/entries/arch*.conf; do
        [[ -f "$entry" ]] || continue
        sed -i "s|^linux .*|linux   ${KERNEL}|" "$entry"
        sed -i '/^initrd /d' "$entry"
        sed -i "/^linux/a initrd  ${UCODE_IMG}\ninitrd  ${INITRD2}" "$entry"
        if grep -q 'root=PARTUUID=' "$entry"; then
          sed -i "s|root=PARTUUID=[^ ]*|root=PARTUUID=${PARTUUID}|" "$entry"
        else
          sed -i "s|root=/dev/[^ ]*|root=PARTUUID=${PARTUUID}|" "$entry" || true
        fi
      done

      if [[ -n "${SWAP:-}" ]]; then
        SWAP_UUID="$(blkid -s UUID -o value "$SWAP")"
        for entry in /mnt/boot/loader/entries/arch*.conf; do
          [[ -f "$entry" ]] || continue
          grep -q ' resume=' "$entry" || sed -i "s|\(^options .*\)|\1 resume=UUID=${SWAP_UUID}|" "$entry"
        done
      fi
      break
      ;;
    "GRUB (UEFI)")
      echo "==> Installing GRUB (UEFI)"
      arch-chroot /mnt pacman --noconfirm -S grub efibootmgr os-prober
      arch-chroot /mnt /bin/bash <<'CHROOT'
set -euo pipefail
if grep -q '^#\?GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
  sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
  echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="GRUB"
os-prober || true
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT
      break
      ;;
    *) echo "Invalid choice";;
  esac
done

### 6) WHAT'S LEFT (manual, once per machine)
cat <<'POST'
---------------------------------------------------------
Base install completed.

Next steps (inside the chroot):
  passwd
  useradd -m -G wheel -s /bin/bash USER && passwd USER
  EDITOR=nvim visudo    # uncomment: %wheel ALL=(ALL) ALL
Optional desktop:
  pacman -S gnome gdm && systemctl enable gdm

When ready:
  exit
  umount -R /mnt
  swapoff -a
  reboot
---------------------------------------------------------
POST
