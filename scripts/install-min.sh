#!/usr/bin/env bash
# scripts/install-min.sh
set -euo pipefail

# --- Prompt (partitions should already exist) ---
read -rp "EFI partition (e.g. /dev/nvme0n1p1 or /dev/sda1): " EFI
read -rp "ROOT partition (e.g. /dev/nvme0n1p3 or /dev/sda3): " ROOT
read -rp "SWAP partition (Enter to skip): " SWAP || true

TZ="Asia/Ho_Chi_Minh"
LOCALE="en_US.UTF-8"
KEYMAP="us"
HOSTNAME="${HOSTNAME:-GloriousArch}"

REPO_ROOT="$(pwd)"
REPO_LOADER="${REPO_ROOT}/boot/loader"

# --- Format & mount ---
mkfs.fat -F32 "$EFI"
mkfs.ext4 -F "$ROOT"
mount "$ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi
if [[ -n "${SWAP:-}" ]]; then mkswap "$SWAP"; swapon "$SWAP"; fi

# --- Base system ---
pacstrap -K /mnt base linux linux-firmware sof-firmware base-devel neovim git networkmanager

# --- fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot base config ---
arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc

# locale
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || true
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname
echo "${HOSTNAME}" > /etc/hostname

# network
systemctl enable NetworkManager

# CPU microcode
VENDOR=\$(lscpu | awk -F: '/Vendor ID/ {gsub(/^[ \\t]+/, "", \$2); print \$2}')
UCODE=amd-ucode; [[ "\$VENDOR" == "GenuineIntel" ]] && UCODE=intel-ucode
pacman --noconfirm -S "\$UCODE"
CHROOT

# --- Bootloader choice ---
echo
echo "Select bootloader:"
select BOOT in "systemd-boot (use repo boot/loader)" "GRUB"; do
  case "$BOOT" in
    "systemd-boot (use repo boot/loader)")
      arch-chroot /mnt bootctl install

      # Copy your repo's boot/loader if present
      if [[ -d "${REPO_LOADER}" ]]; then
        echo "Copying ${REPO_LOADER} -> /mnt/boot/loader"
        if command -v rsync >/dev/null 2>&1; then
          rsync -a --delete "${REPO_LOADER}/" /mnt/boot/loader/
        else
          mkdir -p /mnt/boot/loader
          (cd "${REPO_LOADER}" && tar cf - .) | (cd /mnt/boot/loader && tar xf -)
        fi
      else
        echo "WARN: ${REPO_LOADER} not found; creating minimal loader files"
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
