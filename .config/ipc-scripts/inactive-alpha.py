#!/usr/bin/python3
#
# Modified script to set opacity for all windows with focus-based changes

from wayfire import WayfireSocket

sock = WayfireSocket()
sock.watch(['view-focused', 'view-mapped'])

last_focused_toplevel = -1
DEFAULT_OPACITY = 0.8  # Base opacity for all windows
FOCUSED_OPACITY = 0.9   # Opacity for focused window
INACTIVE_OPACITY = 0.7  # Opacity for inactive windows

def set_all_windows_opacity():
    """Set opacity for all existing windows"""
    try:
        views = sock.list_views()
        for view in views:
            if view["type"] == "toplevel":
                sock.set_view_alpha(view["id"], DEFAULT_OPACITY)
    except Exception as e:
        print(f"Error setting opacity for existing windows: {e}")

# Set opacity for all existing windows when script starts
set_all_windows_opacity()

while True:
    msg = sock.read_next_event()
    if "event" in msg:
        print(msg["event"])

        # Handle new windows
        if msg["event"] == "view-mapped":
            view = msg["view"]
            if view and view["type"] == "toplevel":
                # Set default opacity for new windows
                try:
                    sock.set_view_alpha(view["id"], DEFAULT_OPACITY)
                except Exception as e:
                    print(f"Error setting opacity for new window: {e}")

        # Handle focus changes
        elif msg["event"] == "view-focused":
            view = msg["view"]
            new_focus = view["id"] if view and view["type"] == "toplevel" else -1

            if last_focused_toplevel != new_focus:
                # Set previous window to inactive opacity
                if last_focused_toplevel != -1 and new_focus != -1:
                    try:
                        sock.set_view_alpha(last_focused_toplevel, INACTIVE_OPACITY)
                    except:
                        print("Last focused toplevel was closed?")

                # Set new focused window to full opacity
                if new_focus != -1:
                    sock.set_view_alpha(new_focus, FOCUSED_OPACITY)

                last_focused_toplevel = new_focus
