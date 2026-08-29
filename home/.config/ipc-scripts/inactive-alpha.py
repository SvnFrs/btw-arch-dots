#!/usr/bin/python3
"""Dim inactive toplevels, nhưng nhường quyền cho scale khi overview mở."""
import sys
from wayfire import WayfireSocket

try:
    sock = WayfireSocket()
except Exception as e:
    print(f"Cannot connect to Wayfire IPC: {e}", file=sys.stderr)
    sys.exit(1)

FOCUSED  = 1.0
INACTIVE = 0.85

def is_toplevel(view):
    if not view:
        return False
    role = view.get("role") or view.get("type")
    return role in ("toplevel", "role_toplevel") and view.get("mapped", False)

def set_alpha(view_id, alpha):
    try:
        sock.set_view_alpha(view_id, alpha)
    except Exception as e:
        print(f"set_view_alpha failed for {view_id}: {e}", file=sys.stderr)

def dim_all_inactive(focused_id):
    for v in sock.list_views():
        if is_toplevel(v):
            set_alpha(v["id"], FOCUSED if v["id"] == focused_id else INACTIVE)

def restore_all():
    for v in sock.list_views():
        if is_toplevel(v):
            set_alpha(v["id"], FOCUSED)

# lấy focus hiện tại lúc khởi động
last = -1
for v in sock.list_views():
    if is_toplevel(v) and v.get("activated"):
        last = v["id"]
dim_all_inactive(last)

sock.watch(["view-focused", "plugin-activation-state-changed"])
scale_active = False

while True:
    try:
        msg = sock.read_next_event()
        if not msg:
            continue
        ev = msg.get("event")

        # scale bật/tắt → nhường quyền, không dim khi overview mở
        if ev == "plugin-activation-state-changed" and msg.get("plugin") == "scale":
            if msg.get("state"):        # activated (state=True)
                scale_active = True
                restore_all()           # trả mọi window về 1.0 cho overview đẹp
            else:                       # deactivated
                scale_active = False
                dim_all_inactive(last)  # dim lại theo focus hiện tại
            continue

        # focus đổi → chỉ dim khi KHÔNG trong scale
        if ev == "view-focused" and not scale_active:
            view = msg.get("view")
            new = view["id"] if is_toplevel(view) else -1
            if new != last:
                if last != -1:
                    set_alpha(last, INACTIVE)
                if new != -1:
                    set_alpha(new, FOCUSED)
                last = new
    except KeyboardInterrupt:
        restore_all()   # dọn dẹp khi thoát, không để window kẹt ở alpha thấp
        break
    except Exception as e:
        print(f"Loop error: {e}", file=sys.stderr)
        break