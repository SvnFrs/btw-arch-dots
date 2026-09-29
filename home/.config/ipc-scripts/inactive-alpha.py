#!/usr/bin/python3
"""Dim inactive toplevels, nhưng nhường quyền cho các plugin overview khi chúng mở."""
import sys
from wayfire import WayfireSocket

try:
    sock = WayfireSocket()
except Exception as e:
    print(f"Cannot connect to Wayfire IPC: {e}", file=sys.stderr)
    sys.exit(1)

FOCUSED  = 1.0
INACTIVE = 0.85

# Các plugin overview: khi một trong số này mở, mọi window phải về alpha 1.0.
# Tên lấy từ grab interface của plugin (output.cpp: data.plugin_name = owner->name),
# nên "spread-overview" khớp với .name trong overview.hpp.
OVERVIEW_PLUGINS = {"scale", "spread-overview"}

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

# Dùng set thay vì cờ bool: nếu có nhiều overview cùng bật/tắt, restore và dim vẫn cân bằng.
active_overviews = set()

while True:
    try:
        msg = sock.read_next_event()
        if not msg:
            continue
        ev = msg.get("event")

        # overview bật/tắt → nhường quyền, không dim khi overview mở
        plugin = msg.get("plugin")
        if ev == "plugin-activation-state-changed" and plugin in OVERVIEW_PLUGINS:
            if msg.get("state"):            # activated (state=True)
                active_overviews.add(plugin)
                if len(active_overviews) == 1:
                    restore_all()           # trả mọi window về 1.0 cho overview đẹp
            else:                           # deactivated
                active_overviews.discard(plugin)
                if not active_overviews:
                    dim_all_inactive(last)  # dim lại theo focus hiện tại
            continue

        # focus đổi → chỉ dim khi KHÔNG có overview nào đang mở.
        # Mở overview làm focus đổi, nên nếu thiếu guard này thì window đang active
        # bị dim ngay giữa overview (đúng lỗi đã gặp với spread-overview).
        if ev == "view-focused" and not active_overviews:
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