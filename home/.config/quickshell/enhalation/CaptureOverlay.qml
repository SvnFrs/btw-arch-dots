import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

// docs/capture-ui.md §3: the capture overlay, one per output (shell.qml's Variants). It shows
// the freeze actions.sh took *before* it mapped (what you select is what you get), and on the
// shutter hands physical px to `actions.sh shot-crop`. It never runs grim itself.
PanelWindow {
    id: ov

    required property var modelData          // the ShellScreen
    required property QtObject capture       // shared state, shell.qml
    screen: modelData

    readonly property bool active: capture.open && capture.output === modelData.name
    readonly property real dpr: modelData.devicePixelRatio
    readonly property string dir: Quickshell.env("XDG_RUNTIME_DIR") + "/capture"
    readonly property string actions: Quickshell.env("HOME") + "/.config/swaync/actions.sh"
    readonly property bool area: capture.mode === "area"

    property rect sel: Qt.rect(0, 0, 0, 0)   // logical px
    property bool dragged: false             // the hint leaves after the first drag
    property var pending: []

    // §3: overlay layer, exclusive keyboard focus while open, full-screen on its output.
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "enhalation-capture"
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    visible: active || content.opacity > 0.01

    onActiveChanged: if (active) reset()
    Connections {
        target: ov.capture
        function onSelectRequested(r) { if (ov.active) ov.sel = r; }
        function onShootRequested() { if (ov.active) ov.shoot(); }
        function onPlanRequested() { if (ov.active) ov.capture.plan = ov.cropArgs().join(" "); }
    }

    // Area starts from the session's last area, else a centred 640×360; Screen is the output.
    // Use the SCREEN's size: when `active` flips, the window has not been sized to it yet.
    function reset() {
        const last = capture.lastArea, W = modelData.width, H = modelData.height;
        sel = last.width > 0 ? last
            : Qt.rect(Math.round((W - 640) / 2), Math.round((H - 360) / 2), 640, 360);
        dragged = false;
        keys.forceActiveFocus();
    }
    function shootRect() { return area ? sel : Qt.rect(0, 0, modelData.width, modelData.height); }
    // logical → physical px (§2.3); actions.sh crops the freeze with ffmpeg
    function cropArgs() {
        const r = shootRect();
        return ["shot-crop"].concat([r.x, r.y, r.width, r.height].map(v => String(Math.round(v * dpr))),
                                    capture.pointer ? ["cursor"] : []);
    }
    function shoot() {
        const r = shootRect();
        if (r.width < 1 || r.height < 1) return;
        if (area) capture.lastArea = sel;
        pending = ["bash", actions].concat(cropArgs());
        capture.open = false;                // leave (150 ms), then crop
        cropLater.restart();
    }
    Timer { id: cropLater; interval: Theme.durExit + 30; onTriggered: Quickshell.execDetached(ov.pending) }

    Item {
        id: keys
        focus: true
        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) { ov.shoot(); e.accepted = true; }
            else if (e.key === Qt.Key_Escape) { ov.capture.open = false; e.accepted = true; }
        }
    }

    Item {
        id: content
        anchors.fill: parent
        // Enter: scrim fade 180 ms; leave: 150 ms ease-exit.
        opacity: ov.active ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: ov.active ? Theme.durHover : Theme.durExit
                easing.type: Easing.BezierSpline
                easing.bezierCurve: ov.active ? Theme.easeOutExpo : Theme.easeExit
            }
        }

        Image {                                  // the freeze (Pointer ON shows the one with the cursor)
            anchors.fill: parent
            source: ov.active ? "file://" + ov.dir + (ov.capture.pointer ? "/freeze-cursor.png" : "/freeze.png")
                                + "?s=" + ov.capture.serial : ""
            cache: false
            smooth: false
        }

        // scrim outside the selection (Area); Screen takes the whole output, so none
        Repeater {
            model: ov.area ? 4 : 0
            Rectangle {
                required property int index
                color: Theme.captureScrim
                readonly property rect s: ov.sel
                x: index === 3 ? s.x + s.width : 0
                y: index === 0 ? 0 : index === 1 ? s.y + s.height : s.y
                width: index === 2 ? s.x : index === 3 ? parent.width - (s.x + s.width) : parent.width
                height: index === 0 ? s.y : index === 1 ? parent.height - (s.y + s.height) : s.height
            }
        }

        // selection: 1.5 px ink at 90%, radius 2, corner handles
        Rectangle {
            visible: ov.area && ov.sel.width > 0
            x: ov.sel.x; y: ov.sel.y; width: ov.sel.width; height: ov.sel.height
            color: "transparent"
            radius: 2
            border.width: 1.5
            border.color: Qt.alpha(Theme.ink, 0.9)
        }
        Repeater {
            model: ov.area && ov.sel.width > 0 ? 4 : 0
            Item {                               // 12 px knob: radial thumb-hi → ink, thumb-shadow
                required property int index
                width: 12; height: 12
                x: (index % 2 ? ov.sel.x + ov.sel.width : ov.sel.x) - 6
                y: (index < 2 ? ov.sel.y : ov.sel.y + ov.sel.height) - 6
                RectangularShadow { anchors.fill: parent; radius: 6; offset: Qt.vector2d(0, 2); blur: 6; color: Theme.thumbShadow }
                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeWidth: -1
                        fillGradient: RadialGradient {
                            centerX: 4.2; centerY: 3.6; centerRadius: 8.4; focalX: 4.2; focalY: 3.6
                            GradientStop { position: 0; color: Theme.thumbHi }
                            GradientStop { position: 1; color: Theme.ink }
                        }
                        PathAngleArc { centerX: 6; centerY: 6; radiusX: 6; radiusY: 6; startAngle: 0; sweepAngle: 360 }
                    }
                }
            }
        }

        // pointer: drag to select, inside moves, handles/edges resize (24 px hit targets)
        MouseArea {
            id: pick
            anchors.fill: parent
            enabled: ov.active && ov.area
            hoverEnabled: true
            property string zone: ""
            property string hoverZone: ""
            property point start
            property rect startSel

            function zoneAt(x, y) {
                const s = ov.sel, t = 12;
                if (s.width <= 0) return "new";
                const L = Math.abs(x - s.x) <= t, R = Math.abs(x - (s.x + s.width)) <= t;
                const T = Math.abs(y - s.y) <= t, B = Math.abs(y - (s.y + s.height)) <= t;
                const inX = x >= s.x - t && x <= s.x + s.width + t, inY = y >= s.y - t && y <= s.y + s.height + t;
                if (T && L) return "tl"; if (T && R) return "tr"; if (B && L) return "bl"; if (B && R) return "br";
                if (L && inY) return "l"; if (R && inY) return "r"; if (T && inX) return "t"; if (B && inX) return "b";
                if (x > s.x && x < s.x + s.width && y > s.y && y < s.y + s.height) return "move";
                return "new";
            }
            function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

            cursorShape: ({ tl: Qt.SizeFDiagCursor, br: Qt.SizeFDiagCursor, tr: Qt.SizeBDiagCursor,
                            bl: Qt.SizeBDiagCursor, l: Qt.SizeHorCursor, r: Qt.SizeHorCursor,
                            t: Qt.SizeVerCursor, b: Qt.SizeVerCursor,
                            move: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor })[pressed ? zone : hoverZone]
                         ?? Qt.CrossCursor

            onPressed: (m) => { zone = zoneAt(m.x, m.y); start = Qt.point(m.x, m.y); startSel = ov.sel; }
            onPositionChanged: (m) => {
                if (!pressed) { hoverZone = zoneAt(m.x, m.y); return; }
                const W = width, H = height, dx = m.x - start.x, dy = m.y - start.y, s = startSel;
                let x1 = s.x, y1 = s.y, x2 = s.x + s.width, y2 = s.y + s.height;
                if (zone === "new") { x1 = start.x; y1 = start.y; x2 = m.x; y2 = m.y; }
                else if (zone === "move") {
                    x1 = clamp(s.x + dx, 0, W - s.width); y1 = clamp(s.y + dy, 0, H - s.height);
                    x2 = x1 + s.width; y2 = y1 + s.height;
                } else {
                    if (zone.includes("l")) x1 += dx; if (zone.includes("r")) x2 += dx;
                    if (zone.includes("t")) y1 += dy; if (zone.includes("b")) y2 += dy;
                }
                x1 = clamp(Math.round(x1), 0, W); x2 = clamp(Math.round(x2), 0, W);
                y1 = clamp(Math.round(y1), 0, H); y2 = clamp(Math.round(y2), 0, H);
                ov.sel = Qt.rect(Math.min(x1, x2), Math.min(y1, y2), Math.abs(x2 - x1), Math.abs(y2 - y1));
                ov.dragged = true;
            }
            onReleased: {
                if (ov.sel.width < 4 || ov.sel.height < 4) ov.sel = startSel;   // a click keeps the area
                hoverZone = zone;
            }
        }

        // size chip (physical px), below-right of the selection
        GlassPanel {
            id: chip
            floating: false
            visible: ov.sel.width > 0
            readonly property rect r: ov.shootRect()
            radius: height / 2
            width: sizeText.implicitWidth + 24
            height: 26
            x: Math.min(r.x + r.width - width, parent.width - width - 8)
            y: Math.min(r.y + r.height + 8, parent.height - height - 8)
            Text {
                id: sizeText
                anchors.centerIn: parent
                text: Math.round(chip.r.width * ov.dpr) + " × " + Math.round(chip.r.height * ov.dpr)
                font.family: Theme.font; font.pixelSize: 12
                color: Theme.ink
            }
        }

        // hint: a glass pill 8 px above the toolbar, gone after the first drag; never bare text on the scrim
        GlassPanel {
            floating: false
            visible: ov.area && !ov.dragged
            radius: height / 2
            width: hintText.implicitWidth + 28
            height: 30
            x: (parent.width - width) / 2
            y: toolbar.y - height - 8
            Text {
                id: hintText
                anchors.centerIn: parent
                text: "Drag to select · drag inside to move · Enter captures · Esc cancels"
                font.family: Theme.font; font.pixelSize: 12
                color: Theme.inkMuted
            }
        }

        Toolbar {
            id: toolbar
            x: (parent.width - width) / 2
            // bottom-centre, 24 px above the edge; enter = rise 12 px + fade, 280 ms ease-out-expo
            y: parent.height - height - 24 + (ov.active ? 0 : 12)
            opacity: ov.active ? 1 : 0
            Behavior on y { NumberAnimation { duration: Theme.durEnter; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo } }
            Behavior on opacity { NumberAnimation { duration: Theme.durEnter; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo } }
            mode: ov.capture.mode
            kind: ov.capture.kind
            pointer: ov.capture.pointer
            onModePicked: (key) => { ov.capture.mode = key; }
            onKindPicked: (key) => { ov.capture.kind = key; }
            onPointerToggled: ov.capture.pointer = !ov.capture.pointer
            onShoot: ov.shoot()
            onClose: ov.capture.open = false
        }
    }
}
