# connect to wifi
iwctl

station wlan0 connect "SSID"
# enter password
----------------------------

# if you would like to install on an USB
cfdisk /dev/sda

# if you would like to install on an SSD
cfdisk /dev/nvme0n1

# create partitions
# if your ram is less than 16GB, you should create a swap partition
----------------------------

# format the efi partition
# for USB
mkfs.fat -F32 /dev/sda1
# for SSD
mkfs.fat -F32 /dev/nvme0n1p1

# format the swap partition on if you have any
# for USB
mkswap /dev/sda2
# for SSD
mkswap /dev/nvme0n1p2

# format the root partition
# for USB
mkfs.ext4 /dev/sda3
# for SSD
mkfs.ext4 /dev/nvme0n1p3

# mount the root partition
mount /dev/nvme0n1p3 /mnt

# make the efi folder
mkdir -p /mnt/boot/efi

# mount the efi partition
mount /dev/nvme0n1p1 /mnt/boot/efi

# turn on swap partition
swapon /dev/nvme0n1p2

# start installing packages
pacstrap /mnt base linux linux-zen linux-firmware sof-firmware base-devel grub efibootmgr git neovim networkmanager kitty gnome os-prober

# generate file system
genfstab /mnt > /mnt/etc/fstab

# enter the system
arch-chroot /mnt

# setting the system time
ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime

# sync the system clock
hwclock --systohc

# setting locale
nvim /etc/locale.gen
# should choose 'en_US.UTF-8 UTF-8'

# generate locale
locale-gen

# add locale to /etc/locale.conf as well
nvim /etc/locale.conf
# add this line 'LANG=en_US.UTF-8'

# add keymap to /etc/vconsole.conf
nvim /etc/vconsole.conf
# add this line 'KEYMAP=us'

# add hostname to /etc/hostname
nvim /etc/hostname
# add your favorite hostname
# example: 'ArchBTW'

# set root password
passwd
# enter your password
# example : 'btw'

# add user
useradd -m -G wheel -s /bin/bash USERNAME
# example : 'Iuse'

# set user password
passwd USERNAME
# enter your password
# example : 'btw'

# setup sudo
EDITOR=nvim visudo
# uncomment this line
# '%wheel ALL=(ALL) ALL'
# if you want to use sudo without password, uncomment this line
# '%wheel ALL=(ALL) NOPASSWD: ALL'

# enable network manager
systemctl enable NetworkManager
systemctl enable gdm

# install grub
grub-install /dev/nvme0n1

# generate grub config
grub-mkconfig -o /boot/grub/grub.cfg

# allow os-prober to detect other os
nvim /etc/default/grub
# uncomment this line
# 'GRUB_DISABLE_OS_PROBER=false'

# run os-prober
os-prober

# update grub
grub-mkconfig -o /boot/grub/grub.cfg

# exit the system
exit

# unmount all partitions
umount -a

# reboot the system
reboot
