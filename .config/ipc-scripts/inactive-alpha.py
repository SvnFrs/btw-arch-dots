#!/usr/bin/python3

# SỬA DÒNG IMPORT NÀY:
from wayfire_socket import WayfireSocket
import sys

# Thêm try-except để bắt lỗi kết nối ban đầu
try:
    sock = WayfireSocket()
except Exception as e:
    print(f"Could not connect to Wayfire: {e}")
    sys.exit(1)

sock.watch(['view-focused', 'view-mapped'])

last_focused_toplevel = -1
DEFAULT_OPACITY = 0.8
FOCUSED_OPACITY = 1.0   # Nên để 1.0 (rõ hoàn toàn) thay vì 0.9
INACTIVE_OPACITY = 0.7

def set_all_windows_opacity():
    try:
        views = sock.list_views()
        if views:
            for view in views:
                if view["type"] == "toplevel":
                    sock.set_view_alpha(view["id"], DEFAULT_OPACITY)
    except Exception as e:
        print(f"Error setting opacity: {e}")

set_all_windows_opacity()

while True:
    try:
        msg = sock.read_next_event() # LƯU Ý: Hàm này không có trong class gốc bạn gửi
        # Class gốc dùng read_message(), nhưng để nhận event liên tục
        # chúng ta cần gọi read_message() trong vòng lặp.

        # Sửa lại logic loop một chút để khớp với wayfire_socket.py mới:
        msg = sock.read_message()

        if msg and "event" in msg:
            event_type = msg["event"]

            # Handle new windows
            if event_type == "view-mapped":
                view = msg["view"]
                if view and view["type"] == "toplevel":
                    sock.set_view_alpha(view["id"], DEFAULT_OPACITY)

            # Handle focus changes
            elif event_type == "view-focused":
                view = msg["view"]
                # Khi focus ra background/root, view có thể là None
                new_focus = view["id"] if view and view["type"] == "toplevel" else -1

                if last_focused_toplevel != new_focus:
                    # Làm mờ cửa sổ cũ
                    if last_focused_toplevel != -1:
                        sock.set_view_alpha(last_focused_toplevel, INACTIVE_OPACITY)

                    # Làm rõ cửa sổ mới
                    if new_focus != -1:
                        sock.set_view_alpha(new_focus, FOCUSED_OPACITY)

                    last_focused_toplevel = new_focus
    except KeyboardInterrupt:
        break
    except Exception as e:
        print(f"Loop error: {e}")
        # Nếu mất kết nối socket thì break để restart service hoặc exit
        break