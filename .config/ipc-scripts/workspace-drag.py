#!/usr/bin/python3

import os
from wayfire import WayfireSocket

# Connect to Wayfire socket
socket_path = os.environ.get('WAYFIRE_SOCKET')
if not socket_path:
    # Try default location
    socket_path = f"/tmp/wayfire-{os.environ.get('USER', 'user')}.socket"

try:
    sock = WayfireSocket(socket_path)

    class WorkspaceDragger:
        def __init__(self, socket):
            self.sock = socket
            self.dragging = False
            self.drag_view = None

        def start_monitoring(self):
            # Watch for scale plugin events and mouse movements
            self.sock.watch(['view-geometry-changed', 'plugin-activation-state-changed'])

            while True:
                msg = self.sock.read_next_event()
                if "event" in msg:
                    self.handle_event(msg)

        def handle_event(self, msg):
            if msg["event"] == "plugin-activation-state-changed":
                if msg.get("plugin") == "scale":
                    if msg.get("state") == "activated":
                        print("Scale mode activated - dragging enabled")
                    else:
                        print("Scale mode deactivated")
                        self.dragging = False
                        self.drag_view = None

    dragger = WorkspaceDragger(sock)
    dragger.start_monitoring()

except Exception as e:
    print(f"Error: {e}")
