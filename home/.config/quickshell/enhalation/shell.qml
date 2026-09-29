import QtQuick
import Quickshell
import Quickshell.Io

// docs/capture-ui.md §2.1: one ShellRoot: CaptureOverlay (per screen) + RecIsland.
ShellRoot {
    QtObject {
        id: cap
        property bool open: false
        property string mode: "area"
        property string kind: "photo"
        property bool pointer: false
        property string output: ""                     // the output actions.sh froze
        property int serial: 0                         // busts the freeze image cache
        property rect lastArea: Qt.rect(0, 0, 0, 0)    // remembered for the session (§3)
        property var views: []                         // Window mode, top-most first (§2.4)
        signal selectRequested(rect r)
        signal pickRequested(point p)
        signal shootRequested()
        signal planRequested()
        property string plan: ""
    }

    FileView {
        id: frozenOn
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/capture/freeze-output"
        blockAllReads: true                            // text() after reload() waits for the new file
        printErrors: false
    }
    FileView {                                         // capture-views.py, written by capture-open
        id: viewList
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/capture/views.json"
        blockAllReads: true                            // text() after reload() waits for the new file
        printErrors: false
    }

    IpcHandler {
        target: "capture"
        // actions.sh capture-open calls this after it has taken the freeze (§2.2). `show` is also
        // a `qs ipc` subcommand, so callers must pass `--` (actions.sh qs_call does).
        function show(mode: string, kind: string): void {
            frozenOn.reload();
            viewList.reload();
            const out = frozenOn.text().trim();
            cap.output = out !== "" ? out : (Quickshell.screens.length ? Quickshell.screens[0].name : "");
            try { cap.views = JSON.parse(viewList.text() || "[]"); } catch (e) { cap.views = []; }
            cap.mode = ["area", "screen", "window"].includes(mode) ? mode : "area";
            cap.kind = kind === "video" ? "video" : "photo";
            cap.serial++;
            cap.open = true;
        }
        // Test hooks (no mouse here): set the area in logical px, hover a point in Window mode,
        // press the shutter, cancel.
        function select(x: int, y: int, w: int, h: int): void { cap.selectRequested(Qt.rect(x, y, w, h)); }
        function pick(x: int, y: int): void { cap.pickRequested(Qt.point(x, y)); }
        function shoot(): void { cap.shootRequested(); }
        // What the shutter WOULD run (shot-crop or rec-start), without running it.
        function plan(): string { cap.plan = ""; cap.planRequested(); return cap.plan; }
        function cancel(): void { cap.open = false; }
    }

    Variants {
        model: Quickshell.screens
        CaptureOverlay { capture: cap }
    }

    RecIsland {}
}
