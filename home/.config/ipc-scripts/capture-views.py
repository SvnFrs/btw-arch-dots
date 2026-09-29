#!/usr/bin/python3
"""Window mode for the capture overlay (docs/capture-ui.md §2.4).

Prints the mapped toplevel views on the focused output's current workspace as JSON, top-most
first: [{"id", "app_id", "title", "geometry": {"x", "y", "w", "h"}}], logical px relative to
the output, clipped to it (a window hanging off the edge is captured as far as it is visible).

Wayfire IPC has no stacking order (list-views walks the views in creation order), so the order is
focus order (decision D1): always-on-top first, then last-focus-timestamp, newest first. Wayfire
raises a view when it takes focus, so this matches the screen in normal use; the overlay's hover
outline is exactly what gets captured, so a wrong guess shows before the click.
"""
import json
import sys
from wayfire import WayfireSocket

s = WayfireSocket()
out = s.get_focused_output()
W, H = out["geometry"]["width"], out["geometry"]["height"]

views = []
for v in s.list_views():
    if not v.get("mapped") or v.get("role") != "toplevel" or v.get("minimized"):
        continue
    if v.get("output-name") != out["name"]:
        continue
    g = v["geometry"]                     # relative to the output's current workspace
    x1, y1 = max(g["x"], 0), max(g["y"], 0)
    x2, y2 = min(g["x"] + g["width"], W), min(g["y"] + g["height"], H)
    if x2 - x1 < 1 or y2 - y1 < 1:        # on another workspace (x = 3440, y = -1440, ...)
        continue
    views.append({
        "id": v["id"],
        "app_id": v.get("app-id") or "",
        "title": v.get("title") or "",
        "geometry": {"x": round(x1), "y": round(y1), "w": round(x2 - x1), "h": round(y2 - y1)},
        "_top": bool(v.get("always-on-top")),
        "_ts": v.get("last-focus-timestamp") or 0,
    })

views.sort(key=lambda v: (not v["_top"], -v["_ts"]))
for v in views:
    del v["_top"], v["_ts"]
json.dump(views, sys.stdout)
print()
