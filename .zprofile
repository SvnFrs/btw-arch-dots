if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
  export WLR_NO_HARDWARE_CURSORS=1
  
  #export WLR_DRM_DEVICES=/dev/dri/card0
  
  #export WLR_RENDERER=vulkan
  
  exec wayfire
fi
