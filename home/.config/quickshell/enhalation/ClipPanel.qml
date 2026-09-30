import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

// docs/clipboard-ui.md: the clipboard panel over cliphist. List, filter, search, preview, the
// gliding pill, empty and error states (K2); copy, delete + undo, pin, Clear all and keys (K3).
// Every cliphist / wl-copy call goes through bin/clipctl. Only an explicit copy (click, Enter)
// writes the clipboard: closing by any path (Esc, outside click, focus loss, `clip close`) copies
// nothing. Clip text is always PlainText: a clip is data, never markup.
Scope {
    id: cb

    required property QtObject capture          // shell.qml's capture state: never open over it

    component Caption: Text {
        font.family: Theme.font
        font.pixelSize: 12
        color: Theme.inkMuted
        textFormat: Text.PlainText
    }

    readonly property string home: Quickshell.env("HOME")
    readonly property string clipctl: home + "/.config/quickshell/enhalation/bin/clipctl"
    readonly property string actionsLog: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/swaync-actions.log"

    property bool open: false
    property bool opening: false
    property string output: ""
    property int serial: 0                      // one per open; results from an older open are dropped
    property bool loading: false
    property string error: ""
    property var items: []                      // pins first, then history (newest first)
    property string query: ""
    property string filter: "all"               // all | text | image
    property var shown: []
    property var counts: ({ all: 0, text: 0, image: 0 })
    property int selected: -1
    readonly property var current: selected >= 0 && selected < shown.length ? shown[selected] : null
    readonly property bool showSections: shown.some(i => i.pinned) && shown.some(i => !i.pinned)
    property bool cascade: false                // the first rows after an open cascade in

    // preview: debounced 120 ms; a result for a row that is no longer selected is dropped
    property var preview: null
    property int previewSerial: 0

    // thumbs: at most two clipctl jobs in flight, queued, only for delegates that exist
    property var thumbs: ({})                   // ref -> path ("" = failed)
    property int thumbsVersion: 0
    property var thumbQueue: []
    property var thumbWant: ({})
    property var thumbBusy: ({})
    property int thumbInFlight: 0

    // counters for the test hook (state())
    property int listRuns: 0
    property int thumbStarted: 0
    property int thumbMaxInFlight: 0
    property int thumbDropped: 0
    property int previewDropped: 0
    property int copies: 0
    property int deletes: 0
    property int undos: 0
    property int wipes: 0

    // K3 actions
    property var where: null                    // clipctl whereami: {db, data_home, runtime}
    property bool undoOpen: false               // one delete can be undone, for 6 s
    property string undoLabel: ""
    property bool clearArmed: false             // Clear all: the first click arms it for 3 s
    property string notice: ""                  // a short footer message, 6 s (never clip text)
    readonly property int historyCount: items.filter(i => !i.pinned).length
    Component.onCompleted: run(["whereami"], r => { cb.where = r.error ? null : r; })

    // ── clipctl ───────────────────────────────────────────────────────────────────────────
    Component {
        id: job
        Process {
            id: proc
            property var done: null
            property bool raw: false
            property bool gotOut: false
            property bool gotExit: false
            function finish() { if (gotOut && gotExit) Qt.callLater(() => proc.destroy()); }
            stdout: StdioCollector {
                onStreamFinished: {
                    let r = text;
                    if (!proc.raw) {
                        try { r = JSON.parse(text); } catch (e) { r = { error: "clipctl printed no JSON" }; }
                    }
                    if (proc.done) proc.done(r);
                    proc.gotOut = true;
                    proc.finish();
                }
            }
            onExited: { gotExit = true; finish(); }
        }
    }
    function run(argv, done, raw) {
        job.createObject(cb, { command: raw ? argv : [clipctl].concat(argv), done: done, raw: !!raw }).running = true;
    }
    function logError(msg) {                    // clipctl errors never quote clip contents
        Quickshell.execDetached(["sh", "-c", 'printf "%s clip panel: %s\\n" "$(date "+%F %T")" "$1" >> "$2"',
                                 "sh", msg, actionsLog]);
    }

    // ── open / close ──────────────────────────────────────────────────────────────────────
    function show() {
        if (open || opening || (capture && capture.open)) return;
        serial++;
        const s = serial;
        opening = true; loading = true; error = "";
        query = ""; filter = "all"; preview = null; notice = ""; clearArmed = false;
        items = []; refilter();
        relist(true);
        // the focused output, from Wayfire (the panel opens where you are)
        run(["python3", "-c", "from wayfire import WayfireSocket\nprint(WayfireSocket().get_focused_output()['name'])"], t => {
            if (s !== serial) return;
            const name = String(t || "").trim();
            const screens = Quickshell.screens;
            output = screens.some(sc => sc.name === name) ? name : (screens.length ? screens[0].name : "");
            opening = false;
            open = true;
        }, true);
    }
    // clipctl list + pins, every open and after undo / pin / wipe (undo returns under a NEW id)
    function relist(first) {
        const s = serial;
        listRuns++;
        let list = null, pins = null;
        const merge = () => {
            if (s !== serial || list === null || pins === null) return;
            loading = false;
            const bad = list.error || pins.error;
            if (bad) { error = bad; logError(bad); return; }
            items = pins.items.map(p => entry(p, true)).concat(list.items.map(i => entry(i, false)));
            if (first) { cascade = true; cascadeOff.restart(); }
            refilter();
        };
        run(["list"], r => { list = r; merge(); });
        run(["pins"], r => { pins = r; merge(); });
    }
    function hide() {
        if (!open && !opening) return;
        open = false;
        opening = false;
        serial++;                               // anything still on its way is dropped
        previewTimer.stop();
        thumbDropped += thumbQueue.length;
        thumbQueue = [];
        endUndo();                              // closing ends the undo window: the stash goes
        clearArmed = false;
    }

    // ── actions (K3) ──────────────────────────────────────────────────────────────────────
    function say(msg) { notice = msg; noticeTimer.restart(); }
    Timer { id: noticeTimer; interval: 6000; onTriggered: cb.notice = "" }

    function activate(i) {                      // click / Enter: copy, then close (150 ms)
        const it = shown[i];
        if (!it) return;
        selected = i;
        const s = serial;
        run(it.pinned ? ["copy-pin", it.ref.slice(4)] : ["copy", it.ref], r => {
            if (s !== serial) return;
            if (r.error) { cb.say("Couldn't copy — see the log"); cb.logError(r.error); return; }
            cb.copies++;
            cb.hide();
        });
    }
    function remove(i) {                        // delete button / Delete: history rows can be undone
        const it = shown[i];
        if (!it) return;
        if (it.pinned) { togglePin(i); return; }   // a pin is removed by unpinning it
        const s = serial;
        run(["delete", it.ref], r => {
            if (s !== serial) return;
            if (r.error) { cb.say("Couldn't delete — see the log"); cb.logError(r.error); return; }
            cb.deletes++;
            cb.dropItem(it.key);
            cb.undoLabel = it.kind === "image" ? it.meta : it.preview;
            cb.notice = "";
            cb.undoOpen = true;
            undoTimer.restart();
        });
    }
    function undo() {
        if (!undoOpen) return;
        undoOpen = false;
        undoTimer.stop();
        const s = serial;
        run(["undo"], r => {
            if (s !== serial) return;
            if (r.error) { cb.say("Couldn't undo — see the log"); cb.logError(r.error); return; }
            cb.undos++;
            cb.relist(false);
        });
    }
    function endUndo() {                        // the window ended: forget the stash (plain unlink)
        if (!undoOpen) return;
        undoOpen = false;
        undoTimer.stop();
        run(["forget"], () => {});
    }
    Timer { id: undoTimer; interval: 6000; onTriggered: cb.endUndo() }
    function togglePin(i) {
        const it = shown[i];
        if (!it) return;
        const s = serial;
        run(it.pinned ? ["unpin", it.ref.slice(4)] : ["pin", it.ref], r => {
            if (s !== serial) return;
            if (r.error) {
                if (r.error.indexOf("pins at most") >= 0) cb.say("20 pins at most — unpin one first");
                else { cb.say("Couldn't pin — see the log"); cb.logError(r.error); }
                return;
            }
            cb.relist(false);
        });
    }
    function clearAll() {                       // two clicks: arm (3 s), then wipe; pins survive
        if (!clearArmed) { clearArmed = true; disarm.restart(); return; }
        clearArmed = false;
        disarm.stop();
        const s = serial;
        run(["wipe"], r => {
            if (s !== serial) return;
            if (r.error) { cb.say("Couldn't clear — see the log"); cb.logError(r.error); return; }
            cb.wipes++;
            cb.undoOpen = false;                // wipe cleared the stash, thumbs and preview
            undoTimer.stop();
            cb.thumbs = ({});
            cb.thumbsVersion++;
            cb.preview = null;
            cb.relist(false);
        });
    }
    Timer { id: disarm; interval: 3000; onTriggered: cb.clearArmed = false }
    function dropItem(key) {                    // remove one row in place, so it can collapse
        items = items.filter(x => x.key !== key);
        const j = shown.findIndex(x => x.key === key);
        if (j < 0) return;
        shown = shown.filter(x => x.key !== key);
        recount();
        rows.remove(j);
        selected = shown.length ? Math.min(j, shown.length - 1) : -1;
    }
    Timer { id: cascadeOff; interval: 500; onTriggered: cb.cascade = false }

    // ── model ─────────────────────────────────────────────────────────────────────────────
    function entry(x, pinned) {
        const ref = pinned ? "pin:" + x.n : String(x.id);
        const img = x.kind === "image";
        const meta = img ? x.fmt + " · " + x.w + "×" + x.h + " · " + x.size : "";
        return {
            key: ref, ref: ref, pinned: pinned, section: pinned ? "Pinned" : "Recent",
            kind: img ? "image" : "text", preview: x.preview || "", hint: x.hint || "text",
            color: x.color || "", meta: meta,
            search: (img ? meta + " " + x.w + "x" + x.h : x.preview || "").toLowerCase()
        };
    }
    function refilter() {
        const q = query.trim().toLowerCase();
        const hit = q ? items.filter(i => i.search.indexOf(q) >= 0) : items;
        counts = countOf(hit);
        shown = filter === "all" ? hit : hit.filter(i => i.kind === filter);
        rows.clear();
        for (const i of shown)
            rows.append({ key: i.key, ref: i.ref, kind: i.kind, section: i.section, pinned: i.pinned,
                          label: i.kind === "image" ? i.meta : i.preview, hint: i.hint, swatch: i.color });
        selected = shown.length ? 0 : -1;
    }
    function countOf(hit) {
        const c = { all: hit.length, text: 0, image: 0 };
        for (const i of hit) c[i.kind]++;
        return c;
    }
    function recount() {
        const q = query.trim().toLowerCase();
        counts = countOf(q ? items.filter(i => i.search.indexOf(q) >= 0) : items);
    }
    onQueryChanged: refilter()
    onFilterChanged: refilter()
    ListModel { id: rows }

    function move(d) {
        if (!shown.length) return;
        selected = Math.max(0, Math.min(shown.length - 1, selected + d));
    }

    // ── preview ───────────────────────────────────────────────────────────────────────────
    onCurrentChanged: previewTimer.restart()
    Timer { id: previewTimer; interval: 120; onTriggered: cb.loadPreview() }
    function loadPreview() {
        const it = current;
        if (!it) { preview = null; return; }
        if (preview && preview.key === it.key) return;
        const key = it.key, s = serial;
        run([it.kind === "image" ? "preview" : "text", it.ref], r => {
            if (s !== serial || !cb.current || cb.current.key !== key) { cb.previewDropped++; return; }
            if (r.error) { cb.preview = { key: key, kind: "error" }; cb.logError(r.error); return; }
            cb.previewSerial++;
            cb.preview = Object.assign({ key: key, kind: it.kind, hint: it.hint, color: it.color,
                                           serial: cb.previewSerial }, r);
        });
    }

    // ── thumbs ────────────────────────────────────────────────────────────────────────────
    function wantThumb(ref) {
        thumbWant[ref] = (thumbWant[ref] || 0) + 1;
        if (thumbs[ref] === undefined && !thumbBusy[ref] && thumbQueue.indexOf(ref) < 0) {
            thumbQueue.push(ref);
            pumpThumbs();
        }
    }
    function unwantThumb(ref) {
        const n = (thumbWant[ref] || 0) - 1;
        if (n > 0) { thumbWant[ref] = n; return; }
        delete thumbWant[ref];
        const i = thumbQueue.indexOf(ref);
        if (i >= 0) { thumbQueue.splice(i, 1); thumbDropped++; }
    }
    function pumpThumbs() {
        while (thumbInFlight < 2 && thumbQueue.length) {
            const ref = thumbQueue.shift();
            thumbBusy[ref] = true;
            thumbInFlight++;
            thumbStarted++;
            thumbMaxInFlight = Math.max(thumbMaxInFlight, thumbInFlight);
            run(["thumb", ref], r => {
                cb.thumbInFlight--;
                delete cb.thumbBusy[ref];
                cb.thumbs[ref] = r.error ? "" : r.thumb;
                cb.thumbsVersion++;
                cb.pumpThumbs();
            });
        }
    }

    IpcHandler {
        target: "clip"
        function ping(): string { return "pong"; }
        function open(): void { cb.show(); }
        function close(): void { cb.hide(); }
        // Super+V / Super+Shift+V: a second press hides it (Tyler, 2026-09-30). `open` stays idempotent.
        function toggle(): void { if (cb.open || cb.opening) cb.hide(); else cb.show(); }
        // Test hooks (no mouse here). state() reports keys, kinds and counts, never clip text.
        function search(q: string): void { cb.query = q; }
        function pick(kind: string): void { if (["all", "text", "image"].includes(kind)) cb.filter = kind; }
        function select(i: int): void { if (i >= 0 && i < cb.shown.length) cb.selected = i; }
        function scroll(i: int): void { cb.scrollTo(i); }
        // the actions, through the same functions the mouse and keys use
        function activate(i: int): void { cb.activate(i); }
        function remove(i: int): void { cb.remove(i); }
        function pin(i: int): void { cb.togglePin(i); }
        function undo(): void { cb.undo(); }
        function clear(): void { cb.clearAll(); }
        function state(): string {
            return JSON.stringify({
                open: cb.open, loading: cb.loading, error: cb.error !== "", filter: cb.filter,
                counts: cb.counts, shown: cb.shown.length, selected: cb.selected,
                selectedKey: cb.current ? cb.current.key : null,
                previewKey: cb.preview ? cb.preview.key : null, previewKind: cb.preview ? cb.preview.kind : null,
                listRuns: cb.listRuns, thumbStarted: cb.thumbStarted, thumbInFlight: cb.thumbInFlight,
                thumbMaxInFlight: cb.thumbMaxInFlight, thumbQueued: cb.thumbQueue.length,
                thumbDropped: cb.thumbDropped, thumbsDone: Object.keys(cb.thumbs).length,
                previewDropped: cb.previewDropped,
                where: cb.where, copies: cb.copies, deletes: cb.deletes, undos: cb.undos, wipes: cb.wipes,
                undoOpen: cb.undoOpen, clearArmed: cb.clearArmed, notice: cb.notice,
                pinned: cb.items.filter(i => i.pinned).length, history: cb.historyCount,
                topKey: cb.items.length ? cb.items.filter(i => !i.pinned).map(i => i.key)[0] || null : null
            });
        }
    }
    signal scrollRequested(int i)
    function scrollTo(i) { scrollRequested(i); }

    // ── the window: one per screen, active on the focused one ─────────────────────────────
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            readonly property bool active: cb.open && cb.output === modelData.name

            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"                // no scrim (§1 Window)
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "enhalation-clip"
            WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            visible: active || panel.opacity > 0.01

            onActiveChanged: if (active) { search.text = ""; search.forceActiveFocus(); }

            // focus loss closes (another exclusive surface, e.g. the capture overlay)
            Item {
                id: focusWatch
                property bool wasActive: false
                readonly property bool winActive: Window.active
                onWinActiveChanged: {
                    if (winActive && win.active) wasActive = true;
                    else if (!winActive && wasActive) { wasActive = false; if (win.active) cb.hide(); }
                }
            }

            MouseArea {                         // a click outside the panel closes it
                anchors.fill: parent
                enabled: win.active
                onClicked: cb.hide()
            }

            GlassPanel {
                id: panel
                width: 1040
                height: 620
                anchors.centerIn: parent
                // open: 280 ms ease-out-expo, scale .97 -> 1 + fade; close: 150 ms ease-exit
                opacity: win.active ? 1 : 0
                scale: win.active ? 1 : 0.97
                Behavior on opacity {
                    NumberAnimation { duration: win.active ? Theme.durEnter : Theme.durExit; easing.type: Easing.BezierSpline
                                      easing.bezierCurve: win.active ? Theme.easeOutExpo : Theme.easeExit }
                }
                Behavior on scale {
                    NumberAnimation { duration: win.active ? Theme.durEnter : Theme.durExit; easing.type: Easing.BezierSpline
                                      easing.bezierCurve: win.active ? Theme.easeOutExpo : Theme.easeExit }
                }

                MouseArea { anchors.fill: parent }          // clicks on the panel never reach "outside"

                Item {
                    anchors.fill: parent
                    anchors.margins: 16

                    // ── header ──
                    Row {
                        id: header
                        width: parent.width
                        height: Theme.clipChipH
                        spacing: 12

                        Item {                                  // the chip: the warm core
                            width: Theme.clipChipW
                            height: Theme.clipChipH
                            Image { anchors.fill: parent; source: "assets/core-chip.png"; smooth: false }
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Text { text: Theme.gClip; font.family: Theme.font; font.pixelSize: 14; color: Theme.onHalo }
                                Text {
                                    text: "clipboard"
                                    font.family: Theme.font; font.pixelSize: 14
                                    font.bold: true; font.italic: true
                                    color: Theme.onHalo
                                }
                            }
                        }

                        Rectangle {                             // search: well, 2 px line-strong baseline
                            id: searchBox
                            width: header.width - Theme.clipChipW - filterSeg.width - clearAll.width - 3 * header.spacing
                            height: Theme.clipChipH
                            radius: 10
                            color: Theme.well
                            clip: true
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Theme.lineStrong }
                            Text {
                                id: searchGlyph
                                x: 16
                                anchors.verticalCenter: parent.verticalCenter
                                text: Theme.gSearch
                                font.family: Theme.font; font.pixelSize: 14
                                color: Theme.inkMuted
                            }
                            TextInput {
                                id: search
                                anchors.left: searchGlyph.right
                                anchors.leftMargin: 12
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                font.family: Theme.font; font.pixelSize: 14
                                font.features: { "liga": 0, "calt": 0 }
                                color: Theme.ink
                                selectionColor: Theme.pillHover
                                selectedTextColor: Theme.ink
                                clip: true
                                cursorDelegate: Rectangle { width: 2; color: Theme.accent }
                                onTextChanged: cb.query = text
                                Keys.onUpPressed: cb.move(-1)
                                Keys.onDownPressed: cb.move(1)
                                Keys.onEscapePressed: cb.hide()
                                // Enter copies; Delete deletes when there is nothing ahead of the caret to
                                // delete (so it still edits a search mid-text); Ctrl+P pins / unpins.
                                Keys.onPressed: (e) => {
                                    if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                                        cb.activate(cb.selected); e.accepted = true;
                                    } else if (e.key === Qt.Key_Delete && search.cursorPosition === search.text.length) {
                                        cb.remove(cb.selected); e.accepted = true;
                                    } else if (e.key === Qt.Key_P && (e.modifiers & Qt.ControlModifier)) {
                                        cb.togglePin(cb.selected); e.accepted = true;
                                    }
                                }
                                Text {                          // placeholder: examples, never a label
                                    visible: !search.text
                                    x: 8                        // clear of the caret, as in the mock
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "ssh, https://, #hex…"
                                    font: search.font
                                    color: Theme.inkMuted
                                }
                            }
                        }

                        Segmented {
                            id: filterSeg
                            anchors.verticalCenter: parent.verticalCenter
                            current: cb.filter
                            options: [
                                { key: "all", label: "All", count: cb.counts.all },
                                { key: "text", label: "Text", count: cb.counts.text },
                                { key: "image", glyph: Theme.gPhoto, label: "Images", count: cb.counts.image }
                            ]
                            onPicked: (key) => { cb.filter = key; search.forceActiveFocus(); }
                        }

                        Rectangle {                             // Clear all: ghost; armed = danger-soft + rim
                            id: clearAll
                            anchors.verticalCenter: parent.verticalCenter
                            width: clearRow.implicitWidth + 24
                            height: 40
                            radius: Theme.radiusSm
                            color: cb.clearArmed ? Theme.dangerSoft : clearArea.containsMouse ? Theme.pill : "transparent"
                            border.width: cb.clearArmed ? 1 : 0
                            border.color: Theme.dangerRim
                            opacity: cb.historyCount > 0 ? 1 : Theme.opacityDisabled
                            Behavior on color { ColorAnimation { duration: Theme.durHover } }
                            Row {
                                id: clearRow
                                anchors.centerIn: parent
                                spacing: 6
                                Text { text: Theme.gDelete; font.family: Theme.font; font.pixelSize: 13; color: Theme.danger }
                                Text {
                                    text: cb.clearArmed ? "Clear " + cb.historyCount + (cb.historyCount === 1 ? " clip?" : " clips?") : "Clear all"
                                    font.family: Theme.font; font.pixelSize: 13
                                    color: cb.clearArmed ? Theme.ink : Theme.inkMuted
                                }
                            }
                            MouseArea {
                                id: clearArea
                                anchors.fill: parent
                                enabled: cb.historyCount > 0
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { cb.clearAll(); search.forceActiveFocus(); }
                            }
                        }
                    }

                    // ── body ──
                    Item {
                        id: body
                        anchors.top: header.bottom
                        anchors.topMargin: 12
                        anchors.bottom: footer.top
                        anchors.bottomMargin: 12
                        width: parent.width

                        // empty history, or clipctl failed: one well box across the body
                        Rectangle {
                            anchors.fill: parent
                            visible: !cb.loading && (cb.error !== "" || cb.items.length === 0)
                            radius: 14
                            color: Theme.well
                            Column {
                                anchors.centerIn: parent
                                spacing: 14
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: cb.error !== "" ? "cliphist didn't answer — see the log" : "Nothing copied yet"
                                    font.family: Theme.font; font.pixelSize: 14
                                    color: Theme.inkMuted
                                }
                                Rectangle {                     // glass "Open log"
                                    visible: cb.error !== ""
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: logRow.implicitWidth + 28
                                    height: 36
                                    radius: Theme.radiusSm
                                    color: logArea.containsMouse ? Theme.pillHover : Theme.pill
                                    Row {
                                        id: logRow
                                        anchors.centerIn: parent
                                        spacing: 8
                                        Text { text: Theme.gWarn; font.family: Theme.font; font.pixelSize: 13; color: Theme.danger }
                                        Text { text: "Open log"; font.family: Theme.font; font.pixelSize: 13; color: Theme.ink }
                                    }
                                    MouseArea {
                                        id: logArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { Quickshell.execDetached(["xdg-open", cb.actionsLog]); cb.hide(); }
                                    }
                                }
                            }
                        }

                        // ── list ──
                        ListView {
                            id: list
                            visible: cb.items.length > 0 && cb.error === ""
                            width: 430
                            height: parent.height
                            clip: true
                            model: rows
                            currentIndex: cb.selected
                            cacheBuffer: 132                    // two image rows: thumbs only near the view
                            // delete: the row fades out over 180 ms and the list closes the gap
                            remove: Transition {
                                NumberAnimation { property: "opacity"; to: 0; duration: 180
                                                  easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo }
                            }
                            displaced: Transition {
                                NumberAnimation { property: "y"; duration: 180
                                                  easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo }
                            }
                            boundsBehavior: Flickable.StopAtBounds
                            highlightFollowsCurrentItem: false
                            highlight: Rectangle {              // ONE pill that glides (420 ms spring)
                                y: list.currentItem ? list.currentItem.y : 0
                                width: list.width
                                height: list.currentItem ? list.currentItem.height : 0
                                radius: 10
                                color: Theme.pill
                                Behavior on y { NumberAnimation { duration: Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeSpring } }
                                Behavior on height { NumberAnimation { duration: Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeSpring } }
                                ClippingRectangle {
                                    anchors.fill: parent
                                    radius: parent.radius
                                    color: "transparent"
                                    Rectangle { width: parent.width; height: 1; color: Theme.pillTop }
                                }
                            }
                            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
                            Connections {
                                target: cb
                                function onScrollRequested(i) { list.positionViewAtIndex(i, ListView.Beginning); }
                            }

                            section.property: cb.showSections ? "section" : ""
                            section.delegate: Item {
                                required property string section
                                width: list.width
                                height: 30
                                Caption { x: 12; anchors.bottom: parent.bottom; anchors.bottomMargin: 7; text: section }
                            }

                            delegate: Item {
                                id: row
                                required property int index
                                required property string key
                                required property string ref
                                required property string kind
                                required property bool pinned
                                required property string label
                                required property string hint
                                required property string swatch
                                readonly property bool isImage: kind === "image"
                                readonly property bool sel: ListView.isCurrentItem
                                property string thumbRef: ""
                                width: list.width
                                height: isImage ? 66 : 42

                                // the first 8 rows after an open cascade in, 24 ms apart
                                opacity: 1
                                Component.onCompleted: {
                                    if (isImage) { thumbRef = ref; cb.wantThumb(ref); }
                                    if (cb.cascade && index < 8) { opacity = 0; cascadeIn.start(); }
                                }
                                Component.onDestruction: if (thumbRef) cb.unwantThumb(thumbRef)
                                SequentialAnimation {
                                    id: cascadeIn
                                    PauseAnimation { duration: Math.max(0, row.index) * 24 }   // index is -1 while a row is removed
                                    NumberAnimation { target: row; property: "opacity"; to: 1; duration: Theme.durHover
                                                      easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeOutExpo }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: cb.selected = row.index
                                    onClicked: cb.activate(row.index)
                                }

                                Item {                          // glyph column (text rows), 18 px
                                    visible: !row.isImage
                                    x: 12
                                    width: 18
                                    height: 18
                                    anchors.verticalCenter: parent.verticalCenter
                                    Text {
                                        anchors.centerIn: parent
                                        visible: row.hint !== "color"
                                        text: row.hint === "url" ? Theme.gLink : Theme.gText
                                        font.family: Theme.font; font.pixelSize: 13
                                        color: Theme.inkMuted
                                    }
                                    Rectangle {                 // #hex: a 14 px swatch instead of a glyph
                                        anchors.centerIn: parent
                                        visible: row.hint === "color"
                                        width: 14
                                        height: 14
                                        radius: 3
                                        color: row.swatch || "transparent"
                                        border.width: 1
                                        border.color: Qt.alpha(Theme.ink, 0.10)
                                    }
                                }

                                ClippingRectangle {             // 84 x 48 thumb, radius 7, inset ink x .10
                                    visible: row.isImage
                                    x: 12
                                    width: 84
                                    height: 48
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: 7
                                    color: Theme.well
                                    Image {
                                        anchors.fill: parent
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        source: { cb.thumbsVersion; const p = cb.thumbs[row.ref]; return p ? "file://" + p : ""; }
                                        opacity: status === Image.Ready ? 1 : 0
                                        Behavior on opacity { NumberAnimation { duration: Theme.durHover } }
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 7
                                        color: "transparent"
                                        border.width: 1
                                        border.color: Qt.alpha(Theme.ink, 0.10)
                                    }
                                }

                                Text {
                                    x: row.isImage ? 12 + 84 + 12 : 12 + 18 + 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - x - (row.sel ? (row.pinned ? 46 : 82) : row.pinned ? 34 : 10)
                                    text: row.label
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    maximumLineCount: 1
                                    font.family: Theme.font
                                    font.pixelSize: row.isImage ? 12 : 14
                                    font.weight: row.sel ? Font.DemiBold : Font.Normal
                                    font.features: { "liga": 0, "calt": 0 }
                                    color: row.isImage && !row.sel ? Theme.inkMuted : Theme.ink
                                }

                                Row {                           // hover / selection: pin + delete, 30 px glass
                                    visible: row.sel
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6
                                    Repeater {
                                        // a pin is removed by unpinning, so pinned rows have no delete button
                                        model: row.pinned ? ["pin"] : ["pin", "delete"]
                                        Rectangle {
                                            required property string modelData
                                            width: 30
                                            height: 30
                                            radius: 9
                                            color: btn.containsMouse ? Theme.pillHover : Theme.pill
                                            scale: btn.pressed ? 0.972 : 1
                                            Text {
                                                anchors.centerIn: parent
                                                text: modelData === "pin" ? Theme.gPin : Theme.gDelete
                                                font.family: Theme.font; font.pixelSize: 13
                                                color: modelData === "delete" ? Theme.danger : row.pinned ? Theme.accent : Theme.ink
                                            }
                                            MouseArea {
                                                id: btn
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: modelData === "pin" ? cb.togglePin(row.index) : cb.remove(row.index)
                                            }
                                        }
                                    }
                                }

                                Text {                          // pinned rows always show the pin in accent
                                    visible: row.pinned && !row.sel
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Theme.gPin
                                    font.family: Theme.font; font.pixelSize: 13
                                    color: Theme.accent
                                }
                            }

                        }

                        Caption {                               // a search with no hits
                            x: (list.width - width) / 2
                            y: 40
                            visible: cb.items.length > 0 && cb.error === "" && cb.shown.length === 0
                            text: "No clips match"
                        }

                        // ── preview ──
                        Item {
                            visible: list.visible
                            anchors.left: list.right
                            anchors.leftMargin: 12
                            anchors.right: parent.right
                            height: parent.height

                            Row {                               // meta line
                                id: meta
                                height: 26
                                spacing: 8
                                readonly property var p: cb.preview && cb.current && cb.preview.key === cb.current.key ? cb.preview : null
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !!meta.p && !(meta.p.kind === "text" && meta.p.hint === "color" && meta.p.lines <= 1)
                                    text: !meta.p ? "" : meta.p.kind === "image" ? Theme.gPhoto
                                          : meta.p.lines > 1 ? Theme.gCode : meta.p.hint === "url" ? Theme.gLink : Theme.gText
                                    font.family: Theme.font; font.pixelSize: 13
                                    color: Theme.inkMuted
                                }
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !!meta.p && meta.p.kind === "text" && meta.p.hint === "color" && meta.p.lines <= 1
                                    width: 14; height: 14; radius: 3
                                    color: meta.p && meta.p.color ? meta.p.color : "transparent"
                                    border.width: 1; border.color: Qt.alpha(Theme.ink, 0.10)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: !!meta.p && meta.p.kind !== "error"
                                    text: meta.p && meta.p.kind === "image" ? "Image" : "Text"
                                    font.family: Theme.font; font.pixelSize: 13; font.weight: Font.DemiBold
                                    color: Theme.ink
                                }
                                Caption {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: !meta.p ? "" : meta.p.kind === "image" ? meta.p.fmt + " · " + meta.p.w + "×" + meta.p.h + " · " + meta.p.size
                                          : meta.p.kind === "text" ? meta.p.lines + (meta.p.lines === 1 ? " line · " : " lines · ") + meta.p.chars + " chars"
                                          : "couldn't read this clip — see the log"
                                }
                            }

                            Rectangle {                         // the box: well, radius 14, padding 16
                                id: box
                                anchors.top: meta.bottom
                                anchors.topMargin: 10
                                anchors.bottom: parent.bottom
                                width: parent.width
                                radius: 14
                                color: Theme.well
                                clip: true
                                Rectangle {                     // well-shadow: inset 0 1px 2px glass-shade
                                    width: parent.width; height: 3; radius: 14
                                    gradient: Gradient {
                                        GradientStop { position: 0; color: Theme.well }
                                        GradientStop { position: 1; color: "transparent" }
                                    }
                                }

                                Flickable {                     // text: 13.5 px mono, wrapped, scrollable, no ligatures
                                    id: textFlick
                                    visible: !!meta.p && meta.p.kind === "text"
                                    anchors.fill: parent
                                    anchors.margins: 16
                                    contentHeight: textCol.height
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    Column {
                                        id: textCol
                                        width: textFlick.width
                                        spacing: 10
                                        Text {
                                            width: parent.width
                                            text: meta.p && meta.p.kind === "text" ? meta.p.text : ""
                                            textFormat: Text.PlainText
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            font.family: Theme.font
                                            font.pointSize: 10.125      // 13.5 px at Qt's 96 dpi (pixelSize is int)
                                            font.features: { "liga": 0, "calt": 0 }
                                            color: Theme.ink
                                        }
                                        Caption {
                                            visible: !!meta.p && meta.p.truncated === true
                                            text: "truncated"
                                        }
                                    }
                                }

                                Item {                          // image: fit inside, radius 8
                                    visible: !!meta.p && meta.p.kind === "image"
                                    anchors.fill: parent
                                    anchors.margins: 16
                                    ClippingRectangle {
                                        anchors.centerIn: parent
                                        width: big.paintedWidth
                                        height: big.paintedHeight
                                        radius: 8
                                        color: "transparent"
                                        Image {
                                            id: big
                                            anchors.centerIn: parent
                                            width: box.width - 32
                                            height: box.height - 32
                                            fillMode: Image.PreserveAspectFit
                                            asynchronous: true
                                            cache: false
                                            sourceSize.width: width * win.devicePixelRatio
                                            sourceSize.height: height * win.devicePixelRatio
                                            source: meta.p && meta.p.kind === "image" ? "file://" + meta.p.path + "?" + meta.p.serial : ""
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── footer ──
                    Item {
                        id: footer
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 30
                        Caption {
                            visible: !cb.undoOpen
                            anchors.verticalCenter: parent.verticalCenter
                            text: cb.notice !== "" ? cb.notice : "Click copies · hover for pin and delete · Del deletes · Esc closes"
                        }
                        Row {                                   // after a delete, for 6 s
                            visible: cb.undoOpen
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 12
                            Caption {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(implicitWidth, 560)
                                elide: Text.ElideRight
                                text: "Deleted “" + cb.undoLabel + "”"
                            }
                            Rectangle {                         // glass Undo
                                anchors.verticalCenter: parent.verticalCenter
                                width: undoRow.implicitWidth + 22
                                height: 30
                                radius: 9
                                color: undoArea.containsMouse ? Theme.pillHover : Theme.pill
                                Row {
                                    id: undoRow
                                    anchors.centerIn: parent
                                    spacing: 6
                                    Text { text: Theme.gUndo; font.family: Theme.font; font.pixelSize: 12; color: Theme.ink }
                                    Text { text: "Undo"; font.family: Theme.font; font.pixelSize: 12; color: Theme.ink }
                                }
                                MouseArea {
                                    id: undoArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { cb.undo(); search.forceActiveFocus(); }
                                }
                            }
                        }
                        Caption {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: cb.loading ? "" : cb.counts.all + (cb.counts.all === 1 ? " clip" : " clips")
                                  + (cb.filter === "image" ? " · " + cb.shown.length + " images"
                                     : cb.filter === "text" ? " · " + cb.shown.length + " text" : "")
                        }
                    }
                }
            }
        }
    }
}
