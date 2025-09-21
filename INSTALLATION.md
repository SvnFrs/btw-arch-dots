# Arch Linux Installation Guide

A comprehensive installation script for Arch Linux with GNOME desktop environment.

## Prerequisites

- Arch Linux ISO booted in UEFI mode
- Internet connection
- USB drive or SSD for installation

## Installation Steps

### 1. Connect to WiFi

```bash
iwctl
```
```bash
station wlan0 connect "YOUR_SSID"
```
*Enter your WiFi password when prompted*

### 2. Partition the Disk

**For USB installation:**
```bash
cfdisk /dev/sda
```

**For SSD installation:**
```bash
cfdisk /dev/nvme0n1
```

**Create the following partitions:**
- EFI partition (512MB, type: EFI System)
- Swap partition (optional, recommended if RAM < 16GB)
- Root partition (remaining space, type: Linux filesystem)

### 3. Format Partitions

**EFI Partition:**
```bash
# For USB
mkfs.fat -F32 /dev/sda1
# For SSD
mkfs.fat -F32 /dev/nvme0n1p1
```

**Swap Partition (if created):**
```bash
# For USB
mkswap /dev/sda2
# For SSD
mkswap /dev/nvme0n1p2
```

**Root Partition:**
```bash
# For USB
mkfs.ext4 /dev/sda3
# For SSD
mkfs.ext4 /dev/nvme0n1p3
```

### 4. Mount Partitions

```bash
# Mount root partition (adjust device name as needed)
mount /dev/nvme0n1p3 /mnt

# Create and mount EFI directory
mkdir -p /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi

# Enable swap (if created)
swapon /dev/nvme0n1p2
```

### 5. Install Base System

```bash
pacstrap /mnt base linux linux-firmware sof-firmware base-devel grub efibootmgr git firefox neovim networkmanager kitty gnome os-prober
```

### 6. Generate Filesystem Table

```bash
genfstab /mnt > /mnt/etc/fstab
```

### 7. Enter the New System

```bash
arch-chroot /mnt
```

### 8. Configure System Settings

**Set timezone:**
```bash
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
hwclock --systohc
```

**Configure locale:**
```bash
nvim /etc/locale.gen
```
*Uncomment: `en_US.UTF-8 UTF-8`*

```bash
locale-gen
```

```bash
nvim /etc/locale.conf
```
*Add: `LANG=en_US.UTF-8`*

**Set keymap:**
```bash
nvim /etc/vconsole.conf
```
*Add: `KEYMAP=us`*

**Set hostname:**
```bash
nvim /etc/hostname
```
*Add your desired hostname (e.g., `ArchBTW`)*

### 9. User Management

**Set root password:**
```bash
passwd
```

**Create user:**
```bash
useradd -m -G wheel -s /bin/bash USERNAME
```

**Set user password:**
```bash
passwd USERNAME
```

**Configure sudo:**
```bash
EDITOR=nvim visudo
```
*Uncomment: `%wheel ALL=(ALL) ALL`*
*Optional: For passwordless sudo, uncomment: `%wheel ALL=(ALL) NOPASSWD: ALL`*

### 10. Enable Services

```bash
systemctl enable NetworkManager
systemctl enable gdm
```

### 11. Install and Configure Bootloader

```bash
# Install GRUB
grub-install /dev/nvme0n1

# Generate GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg
```

**Enable dual-boot detection (optional):**
```bash
nvim /etc/default/grub
```
*Uncomment: `GRUB_DISABLE_OS_PROBER=false`*

```bash
# Detect other operating systems
os-prober

# Update GRUB configuration
grub-mkconfig -o /boot/grub/grub.cfg
```

### 12. Finalize Installation

```bash
# Exit chroot environment
exit

# Unmount all partitions
umount -a

# Reboot system
reboot
```

## Post-Installation Notes

- Remove the installation media before the system restarts
- Login with your created user account
- GNOME desktop environment will start automatically
- Configure your system preferences as needed

## Troubleshooting

- If WiFi doesn't work after installation, ensure NetworkManager is running: `systemctl status NetworkManager`
- For boot issues, check UEFI settings and ensure the correct boot device is selected
- If GRUB doesn't detect other operating systems, verify os-prober configuration

---

**Remember to adjust device names (`/dev/sda` vs `/dev/nvme0n1`) based on your storage type!**
