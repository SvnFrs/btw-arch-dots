# Arch Linux Installation Guide

A comprehensive installation script for Arch Linux with support for both systemd-boot and GRUB bootloaders, plus yay AUR helper setup.

## Prerequisites

- Arch Linux ISO booted in UEFI mode
- Internet connection
- USB drive or SSD for installation
- This repository cloned to access boot loader templates

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

### 3. Clone Repository and Run Installation Script

```bash
# Clone the repository
git clone https://github.com/SvnFrs/btw-arch-dots.git
cd btw-arch-dots

# Make the script executable
chmod +x scripts/install-explained.sh

# Run the installation script
./scripts/install-explained.sh
```

The script will prompt you for:
- EFI partition (e.g., `/dev/nvme0n1p1` or `/dev/sda1`)
- ROOT partition (e.g., `/dev/nvme0n1p3` or `/dev/sda3`)
- SWAP partition (optional - press Enter to skip)

### 4. Bootloader Selection

During installation, you'll be prompted to choose between:

**Option 1: systemd-boot**
- Uses your repository's boot loader templates
- Automatically patches PARTUUID and microcode
- Cleaner, simpler boot process
- Recommended for single-boot systems

**Option 2: GRUB**
- Traditional bootloader with os-prober support
- Better for dual-boot setups
- Automatic detection of other operating systems

### 5. Complete User Setup

After the base installation completes, you'll need to manually configure users:

```bash
# Set root password
passwd

# Create your user
useradd -m -G wheel -s /bin/bash USERNAME
passwd USERNAME

# Configure sudo access
EDITOR=nvim visudo
```
*Uncomment: `%wheel ALL=(ALL) ALL`*

### 6. Install Desktop Environment (Optional)

```bash
# Install GNOME desktop
pacman -S gnome gdm
systemctl enable gdm
```

### 7. Install yay AUR Helper

After rebooting and logging in as your user:

```bash
# Install git and base-devel if not already installed
sudo pacman -S --needed git base-devel

# Clone yay repository
git clone https://aur.archlinux.org/yay.git
cd yay

# Build and install yay
makepkg -si

# Clean up
cd ..
rm -rf yay

# Test yay installation
yay --version
```

### 8. Finalize Installation

```bash
# Exit chroot environment
exit

# Unmount all partitions
umount -R /mnt
swapoff -a

# Reboot system
reboot
```

## Script Features

### Automated Configuration
- **Timezone**: Asia/Ho_Chi_Minh (configurable)
- **Locale**: en_US.UTF-8
- **Keymap**: US
- **Hostname**: ArchBTW (configurable via environment variable)

### Smart Detection
- **CPU Microcode**: Automatically detects Intel or AMD and installs appropriate microcode
- **Kernel Support**: Handles both standard linux and linux-zen kernels
- **UUID-based mounting**: Uses UUIDs in fstab for stability

### Bootloader Intelligence
- **systemd-boot**: Copies and patches your repository's boot loader configuration
- **GRUB**: Full UEFI setup with os-prober for dual-boot detection

## Post-Installation Setup

### Essential AUR Packages
```bash
# Popular AUR packages you might want
yay -S visual-studio-code-bin
yay -S google-chrome
yay -S discord
yay -S spotify
```

### System Maintenance
```bash
# Update system and AUR packages
yay -Syu

# Clean package cache
yay -Sc
```

## Customization Options

### Environment Variables
```bash
# Set custom hostname before running script
export HOSTNAME="MyArchSystem"
./scripts/install-explained.sh
```

### Boot Loader Templates
The script uses templates from `./boot/loader/` in your repository. Customize these files before installation to match your preferences.

## Troubleshooting

### Boot Issues
- **systemd-boot**: Check `/boot/loader/entries/` for proper PARTUUID
- **GRUB**: Verify UEFI boot order and secure boot settings
- **General**: Ensure EFI partition is properly mounted and formatted

### Network Issues
```bash
# Check NetworkManager status
systemctl status NetworkManager

# Restart networking
sudo systemctl restart NetworkManager
```

### yay Issues
```bash
# If yay fails to build packages, ensure base-devel is installed
sudo pacman -S base-devel

# Clear yay cache if needed
yay -Sc --aur
```

## Advanced Usage

### Manual Script Components
You can also use the minimal script for faster installation:
```bash
./scripts/install-min.sh
```

### Custom Boot Entries
For systemd-boot users, boot entries are automatically patched, but you can customize them in your repository's `boot/loader/entries/` directory before installation.

---