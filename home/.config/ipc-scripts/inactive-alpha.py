#!/usr/bin/python3
"""Dim inactive toplevels, but step aside for the overview plugins while they are open."""
import sys
from wayfire import WayfireSocket

try:
    sock = WayfireSocket()
except Exception as e:
    print(f"Cannot connect to Wayfire IPC: {e}", file=sys.stderr)
    sys.exit(1)

FOCUSED  = 1.0
INACTIVE = 0.85

# The overview plugins: while any of them is open, every window must be back at alpha 1.0.
# The names come from the plugin's grab interface (output.cpp: data.plugin_name = owner->name),
# so "spread-overview" matches .name in overview.hpp.
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

# pick up the current focus at startup
last = -1
for v in sock.list_views():
    if is_toplevel(v) and v.get("activated"):
        last = v["id"]
dim_all_inactive(last)

sock.watch(["view-focused", "plugin-activation-state-changed"])

# A set rather than a bool flag: if several overviews open/close together, restore and dim stay balanced.
active_overviews = set()

while True:
    try:
        msg = sock.read_next_event()
        if not msg:
            continue
        ev = msg.get("event")

        # an overview opened/closed → step aside; no dimming while an overview is open
        plugin = msg.get("plugin")
        if ev == "plugin-activation-state-changed" and plugin in OVERVIEW_PLUGINS:
            if msg.get("state"):            # activated (state=True)
                active_overviews.add(plugin)
                if len(active_overviews) == 1:
                    restore_all()           # every window back to 1.0 so the overview looks right
            else:                           # deactivated
                active_overviews.discard(plugin)
                if not active_overviews:
                    dim_all_inactive(last)  # dim again by the current focus
            continue

        # focus changed → only dim when NO overview is open.
        # Opening an overview changes focus, so without this guard the active window
        # gets dimmed in the middle of the overview (exactly the bug seen with spread-overview).
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
        restore_all()   # clean up on exit; never leave a window stuck at low alpha
        break
    except Exception as e:
        print(f"Loop error: {e}", file=sys.stderr)
        break