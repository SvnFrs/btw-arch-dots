# install yay
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si

# install nvidia drivers
sudo pacman -S nvidia-dkms nvidia-utils nvidia-settings nvidia-prime cuda
