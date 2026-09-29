import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

// docs/capture-ui.md §4: the recording island. It only READS $XDG_RUNTIME_DIR/capture/rec.json,
// which actions.sh writes (§2.2), and never runs a recorder. Its buttons call actions.sh verbs.
PanelWindow {
    id: win

    readonly property string home: Quickshell.env("HOME")
    readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/capture"
    readonly property string actions: home + "/.config/swaync/actions.sh"

    property var rec: null                  // parsed rec.json; null = idle
    property string phase: "hidden"         // hidden | recording | saved | failed
    property bool expanded: false
    property bool armed: false
    property string dismissed: ""           // key of a saved/failed state that already left
    property real now: Date.now()

    // Hardening: rec.json is a plain file, so only act on what actions.sh would write.
    // Play / Show in folder / Copy take paths under ~/Videos/Recordings; Open log takes
    // the actions log. Anything else in the file is ignored.
    readonly property string recDir: home + "/Videos/Recordings/"
    readonly property string actionsLog: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/swaync-actions.log"
    readonly property string file: rec && typeof rec.file === "string" && rec.file.startsWith(recDir)
                                   && rec.file.indexOf("/../") < 0 ? rec.file : ""
    readonly property string logPath: rec && rec.log === actionsLog ? rec.log : ""

    readonly property string key: rec ? rec.state + ":" + rec.started : ""
    readonly property string mode: phase === "recording"
        ? (armed ? "armed" : expanded ? "expanded" : "collapsed") : phase
    readonly property real elapsed: rec && rec.started ? Math.max(0, now - rec.started) : 0

    // §4: overlay layer, top-left, no keyboard focus, clicks only land on the island itself.
    anchors { top: true; left: true }
    implicitWidth: Theme.islandW + Theme.space4 + 64       // glass-float room to the right…
    implicitHeight: 320                                    // …and below the tallest state
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "enhalation-island"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region { item: island }
    visible: phase !== "hidden" || island.opacity > 0.01

    function clock(ms) {
        const s = Math.floor(ms / 1000), h = Math.floor(s / 3600);
        const p = n => String(n).padStart(2, "0");
        return h > 0 ? h + ":" + p(Math.floor(s % 3600 / 60)) + ":" + p(s % 60)
                     : p(Math.floor(s / 60)) + ":" + p(s % 60);
    }
    function bytes(b) {
        return b >= 1e9 ? (b / 1e9).toFixed(1) + " GB"
             : b >= 1e6 ? (b / 1e6).toFixed(1) + " MB" : Math.max(1, Math.round(b / 1e3)) + " KB";
    }
    function tilde(p) { return p && p.startsWith(home) ? "~" + p.slice(home.length) : (p || ""); }
    function run(argv) { Quickshell.execDetached(argv); }

    function load(text) {
        let r = null;
        try { r = text ? JSON.parse(text) : null; } catch (e) { r = null; }
        const wasRecording = phase === "recording";
        rec = r && ["recording", "saved", "failed"].includes(r.state) ? r : null;
        armed = false;
        if (!rec) {
            phase = "hidden";
        } else if (rec.state === "recording") {
            if (!wasRecording) expanded = false;         // a new recording starts collapsed
            phase = "recording";
        } else {
            phase = key === dismissed ? "hidden" : rec.state;
        }
    }

    // §2.2: FileView watches the file and its directory, so the directory must exist.
    // fileChanged does not reload by itself; a missing file is idle.
    Process {
        running: true
        command: ["mkdir", "-p", win.dir]
        onExited: recFile.reload()
    }
    FileView {
        id: recFile
        path: win.dir + "/rec.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: win.load(text())
        onLoadFailed: win.load("")
    }

    Timer {                                       // the clock
        interval: 1000; repeat: true; triggeredOnStart: true
        running: win.phase === "recording"
        onTriggered: win.now = Date.now()
    }
    Timer {                                       // Saved/Failed leave after 6 s; hovering holds it
        interval: 6000
        running: (win.phase === "saved" || win.phase === "failed") && !hover.hovered
        onTriggered: { win.dismissed = win.key; win.phase = "hidden"; }
    }
    Timer {                                       // Discard stays armed for 3 s
        id: disarm
        interval: 3000
        onTriggered: win.armed = false
    }
    Timer {                                       // collapse 2 s after the pointer leaves
        id: collapseLater
        interval: 2000
        onTriggered: { win.expanded = false; win.armed = false; }
    }

    IpcHandler {
        target: "rec"
        // §2.2: actions.sh sends the notification fallback only when this fails.
        function ping(): string { return "pong"; }
        // Test hooks for the states the mouse reaches by clicking (C1 screenshots).
        function expand(): void { win.expanded = true; win.armed = false; }
        function arm(): void { win.expanded = true; win.armed = true; disarm.restart(); }
        function collapse(): void { win.expanded = false; win.armed = false; }
    }

    // ── building blocks ──────────────────────────────────────────────────────
    component Label: Text {
        font.family: Theme.font
        font.pixelSize: 14
        color: Theme.ink
        verticalAlignment: Text.AlignVCenter
    }

    component Dot: Item {                         // ● 10px danger, glow 0 0 10px danger×.6, breathing
        width: 10; height: 10
        RectangularShadow {
            anchors.fill: parent; radius: 5; blur: 10
            color: Qt.alpha(Theme.danger, 0.6)
        }
        Rectangle { anchors.fill: parent; radius: 5; color: Theme.danger }
        SequentialAnimation on opacity {
            loops: Animation.Infinite
            NumberAnimation { from: 1; to: 0.4; duration: 1200; easing.type: Easing.InOutSine }
            NumberAnimation { from: 0.4; to: 1; duration: 1200; easing.type: Easing.InOutSine }
        }
    }

    component Chip: Rectangle {                   // pill + caption ink-muted
        property alias text: chipText.text
        implicitWidth: chipText.implicitWidth + 20
        implicitHeight: 22
        radius: height / 2
        color: Theme.pill
        Label { id: chipText; anchors.centerIn: parent; font.pixelSize: 12; color: Theme.inkMuted }
    }

    // A glass button: pill, lit top edge, hover pill-hover, press .972 in 90 ms.
    component GlassButton: Rectangle {
        id: gb
        property string glyph: ""
        property color glyphColor: Theme.ink
        property string text: ""
        property color fill: Theme.pill
        property color fillHover: Theme.pillHover
        signal clicked()
        implicitWidth: row.implicitWidth + 28
        implicitHeight: Theme.stopH
        radius: Theme.radiusSm
        color: area.containsMouse ? gb.fillHover : gb.fill
        scale: area.pressed ? 0.972 : 1
        Behavior on color { ColorAnimation { duration: Theme.durHover; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo } }
        Behavior on scale { NumberAnimation { duration: Theme.durPress; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easePress } }
        ClippingRectangle {                       // lit top edge, trimmed by the rounded corners
            anchors.fill: parent
            radius: gb.radius
            color: "transparent"
            Rectangle { width: parent.width; height: 1; color: Theme.pillTop }
        }
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 8
            Label { visible: gb.glyph !== ""; text: gb.glyph; color: gb.glyphColor }
            Label { visible: gb.text !== ""; text: gb.text }
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: gb.clicked()
        }
    }

    // ── the island ───────────────────────────────────────────────────────────
    GlassPanel {
        id: island
        x: Theme.space4
        y: Theme.space4

        readonly property bool present: win.phase !== "hidden"
        readonly property bool pill: win.mode === "collapsed"

        width: pill ? pillRow.implicitWidth + 26 : Theme.islandW          // padding 0 14 0 12
        height: pill ? 36 : card.implicitHeight + 2 * Theme.islandPad
        radius: pill ? height / 2 : Theme.radiusLg
        wash: pill && hover.hovered ? Theme.pillHover : "transparent"

        // §4.2: width, height and radius move together; 420 ms spring open, 280 ms expo close.
        Behavior on width { NumberAnimation { duration: island.pill ? Theme.durEnter : Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: island.pill ? Theme.easeOutExpo : Theme.easeSpring } }
        Behavior on height { NumberAnimation { duration: island.pill ? Theme.durEnter : Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: island.pill ? Theme.easeOutExpo : Theme.easeSpring } }
        Behavior on radius { NumberAnimation { duration: island.pill ? Theme.durEnter : Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: island.pill ? Theme.easeOutExpo : Theme.easeSpring } }

        // Appear 280 ms (scale .92 → 1 + fade, from the corner); leave 150 ms ease-exit.
        transformOrigin: Item.TopLeft
        opacity: present ? 1 : 0
        scale: present ? 1 : 0.92
        Behavior on opacity { NumberAnimation { duration: island.present ? Theme.durEnter : Theme.durExit; easing.type: Easing.BezierSpline; easing.bezierCurve: island.present ? Theme.easeOutExpo : Theme.easeExit } }
        Behavior on scale { NumberAnimation { duration: island.present ? Theme.durEnter : Theme.durExit; easing.type: Easing.BezierSpline; easing.bezierCurve: island.present ? Theme.easeOutExpo : Theme.easeExit } }

        HoverHandler {
            id: hover
            cursorShape: island.pill ? Qt.PointingHandCursor : Qt.ArrowCursor
            onHoveredChanged: {
                if (hovered) collapseLater.stop();
                else if (win.expanded) collapseLater.restart();
            }
        }

        // 1 · collapsed pill: ● REC 00:42
        Row {
            id: pillRow
            x: 12
            height: 36
            spacing: 8
            opacity: island.pill ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: Theme.durHover } }
            Dot { anchors.verticalCenter: parent.verticalCenter }
            Label { height: 36; text: "REC"; font.pixelSize: 13; font.weight: Font.Bold; font.letterSpacing: 13 * 0.08 }
            Label { height: 36; text: win.clock(win.elapsed); font.pixelSize: 13 }
        }
        TapHandler {
            enabled: island.pill
            onTapped: { win.expanded = true; win.armed = false; }
        }

        // 2–5 · the card
        Column {
            id: card
            x: Theme.islandPad
            y: Theme.islandPad
            width: Theme.islandW - 2 * Theme.islandPad
            spacing: Theme.space3
            opacity: island.pill ? 0 : 1
            visible: opacity > 0
            // Contents crossfade 180 ms, starting 120 ms into the open.
            Behavior on opacity {
                SequentialAnimation {
                    PauseAnimation { duration: island.pill ? 0 : 120 }
                    NumberAnimation { duration: Theme.durHover }
                }
            }

            // header: status mark, title, chip, timer (recording)
            Item {
                width: parent.width
                height: 36
                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8
                    Dot { visible: win.phase === "recording"; anchors.verticalCenter: parent.verticalCenter }
                    Label { visible: win.phase === "saved"; text: Theme.gCheck; color: Theme.spark }
                    Label { visible: win.phase === "failed"; text: Theme.gWarn; color: Theme.danger }
                    Label {
                        text: win.phase === "saved" ? "Saved" : win.phase === "failed" ? "Recording failed" : "Recording"
                        font.weight: Font.Bold
                    }
                    Chip {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text !== ""
                        text: {
                            if (!win.rec) return "";
                            if (win.phase === "recording")
                                return win.rec.mode === "area" && win.rec.geometry
                                    ? "Area " + win.rec.geometry.split(" ")[1].replace("x", "×") : "Screen";
                            if (win.phase === "saved" && win.rec.duration_ms != null)
                                return win.clock(win.rec.duration_ms)
                                    + (win.rec.size != null ? " · " + win.bytes(win.rec.size) : "");
                            return "";
                        }
                    }
                }
                Label {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: win.phase === "recording"
                    text: win.clock(win.elapsed)
                    font.pixelSize: 28
                }
                TapHandler {                      // §4.2: clicking the header collapses
                    enabled: win.phase === "recording"
                    onTapped: { win.expanded = false; win.armed = false; }
                }
            }

            // meta: audio + file (recording) or the path (saved / failed)
            Row {
                visible: win.phase === "recording"
                width: parent.width
                spacing: 8
                Label { text: Theme.gVolume; font.pixelSize: 12; color: Theme.inkMuted }
                Label { id: audio; text: "Desktop audio"; font.pixelSize: 12; color: Theme.inkMuted }
                Label {
                    width: parent.width - x
                    text: win.file.split("/").pop()
                    font.pixelSize: 12; color: Theme.inkMuted
                    elide: Text.ElideMiddle
                }
            }
            Label {
                visible: win.phase === "saved" || win.phase === "failed"
                width: parent.width
                text: win.tilde(win.phase === "failed" ? win.logPath : win.file)
                font.pixelSize: 12; color: Theme.inkMuted
                elide: Text.ElideMiddle
            }

            // actions · recording: Stop and save (the warm core) + Discard
            Row {
                visible: win.mode === "expanded"
                spacing: Theme.islandGap
                Image {
                    id: stop
                    width: Theme.stopW; height: Theme.stopH
                    source: "assets/core-stop.png"
                    smooth: false
                    scale: stopArea.pressed ? 0.972 : 1
                    Behavior on scale { NumberAnimation { duration: Theme.durPress; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easePress } }
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Label { text: Theme.gStop; color: Theme.onHalo }
                        Label { text: "Stop and save"; color: Theme.onHalo; font.weight: Font.DemiBold }
                    }
                    MouseArea {
                        id: stopArea
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.run(["bash", win.actions, "rec-stop"])
                    }
                }
                GlassButton {
                    width: Theme.islandSideW
                    glyph: Theme.gDelete; glyphColor: Theme.danger
                    text: "Discard"
                    onClicked: { win.armed = true; disarm.restart(); }
                }
            }

            // actions · discard armed (3 s): no warm core
            Row {
                visible: win.mode === "armed"
                spacing: Theme.islandGap
                GlassButton {
                    width: Theme.stopW
                    glyph: Theme.gPlay
                    text: "Keep going"
                    onClicked: { win.armed = false; disarm.stop(); }
                }
                GlassButton {
                    width: Theme.islandSideW
                    fill: Theme.dangerSoft; fillHover: Theme.dangerSoft
                    border.width: 1; border.color: Theme.dangerRim
                    glyph: Theme.gDelete; glyphColor: Theme.danger
                    text: "Delete it"
                    onClicked: win.run(["bash", win.actions, "rec-discard"])
                }
            }

            // actions · saved
            Row {
                visible: win.phase === "saved"
                spacing: Theme.islandGap
                GlassButton {
                    glyph: Theme.gPlay; text: "Play"
                    onClicked: if (win.file) win.run(["xdg-open", win.file])
                }
                GlassButton {
                    glyph: Theme.gFolder; text: "Show in folder"
                    onClicked: if (win.file) showItem.running = true
                }
                GlassButton {
                    implicitWidth: Theme.stopH
                    glyph: Theme.gCopy
                    onClicked: if (win.file) win.run(["wl-copy", win.file])
                }
            }

            // actions · failed
            Row {
                visible: win.phase === "failed"
                GlassButton {
                    glyph: Theme.gWarn; glyphColor: Theme.danger
                    text: "Open log"
                    onClicked: if (win.logPath) win.run(["xdg-open", win.logPath])
                }
            }
        }
    }

    // Show in folder: the file manager's FileManager1.ShowItems, else open the directory.
    Process {
        id: showItem
        command: ["gdbus", "call", "--session", "--dest", "org.freedesktop.FileManager1",
                  "--object-path", "/org/freedesktop/FileManager1",
                  "--method", "org.freedesktop.FileManager1.ShowItems",
                  "['" + encodeURI("file://" + win.file) + "']", ""]
        onExited: (code) => {
            if (code !== 0 && win.file)
                win.run(["xdg-open", win.file.slice(0, win.file.lastIndexOf("/"))]);
        }
    }
}
