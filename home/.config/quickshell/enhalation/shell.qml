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
        signal selectRequested(rect r)
        signal shootRequested()
        signal planRequested()
        property string plan: ""
    }

    FileView {
        id: frozenOn
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/capture/freeze-output"
        blockLoading: true
        printErrors: false
    }

    IpcHandler {
        target: "capture"
        // actions.sh capture-open calls this after it has taken the freeze (§2.2).
        function show(mode: string, kind: string): void {
            frozenOn.reload();
            const out = frozenOn.text().trim();
            cap.output = out !== "" ? out : (Quickshell.screens.length ? Quickshell.screens[0].name : "");
            cap.mode = mode === "screen" ? "screen" : "area";      // Window mode: C4
            cap.kind = "photo";                                     // Video: C4
            cap.serial++;
            cap.open = true;
        }
        // Test hooks (no mouse here): set the area in logical px, press the shutter, cancel.
        function select(x: int, y: int, w: int, h: int): void { cap.selectRequested(Qt.rect(x, y, w, h)); }
        function shoot(): void { cap.shootRequested(); }
        // The shot-crop the shutter WOULD run, without running it (no clipboard write).
        function plan(): string { cap.plan = ""; cap.planRequested(); return cap.plan; }
        function cancel(): void { cap.open = false; }
    }

    Variants {
        model: Quickshell.screens
        CaptureOverlay { capture: cap }
    }

    RecIsland {}
}
