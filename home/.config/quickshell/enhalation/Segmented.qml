import QtQuick
import Quickshell.Widgets

// docs/capture-ui.md §3: a glass-native segmented control. The track is a well (radius 16,
// pad 4) with its inset shade; the selected option is a pill + pill-top that glides between
// options (420 ms spring). Selected = ink, Demi Bold; others ink-muted (pill-on-well is gated).
Item {
    id: root

    property var options: []            // [{ key, glyph, label, enabled }]; glyph optional
    property var counts: ({})           // optional { key: number }, shown after the label. Kept out of
                                        // `options` so a count change never rebuilds the options.
    property string current: ""
    signal picked(string key)

    readonly property int currentIndex: root.options.findIndex(o => o.key === root.current)
    property int itemsVersion: 0        // bumped when the Repeater (re)creates items

    implicitWidth: row.implicitWidth + 8
    implicitHeight: 48

    ClippingRectangle {                  // the well
        anchors.fill: parent
        radius: 16
        color: Theme.well
        Rectangle {                      // well-shadow: inset 0 1px 2px glass-shade
            width: parent.width
            height: 3
            gradient: Gradient {
                GradientStop { position: 0; color: Theme.well }
                GradientStop { position: 1; color: "transparent" }
            }
        }
    }

    Rectangle {                          // the gliding selection pill
        // itemAt() is a call, not a property: re-resolve when the items are rebuilt, or the pill
        // keeps pointing at a destroyed item and stays hidden (seen on the clipboard's "All").
        readonly property Item target: { root.itemsVersion; return root.currentIndex >= 0 ? optionItems.itemAt(root.currentIndex) : null; }
        visible: target !== null
        x: target ? target.x + 4 : 4
        y: 4
        width: target ? target.width : 0
        height: 40
        radius: Theme.radiusSm
        color: Theme.pill
        Behavior on x { NumberAnimation { duration: Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeSpring } }
        Behavior on width { NumberAnimation { duration: Theme.durSlide; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easeSpring } }
        ClippingRectangle {
            anchors.fill: parent
            radius: parent.radius
            color: "transparent"
            Rectangle { width: parent.width; height: 1; color: Theme.pillTop }
        }
    }

    Row {
        id: row
        x: 4
        y: 4
        Repeater {
            id: optionItems
            model: root.options
            onItemAdded: root.itemsVersion++
            Item {
                required property var modelData
                readonly property bool selected: modelData.key === root.current
                readonly property bool usable: modelData.enabled !== false
                width: content.implicitWidth + 28
                height: 40
                opacity: usable ? 1 : Theme.opacityDisabled
                Row {
                    id: content
                    anchors.centerIn: parent
                    spacing: 8
                    Text {
                        visible: !!modelData.glyph
                        text: modelData.glyph || ""
                        font.family: Theme.font; font.pixelSize: 14
                        color: selected ? Theme.ink : Theme.inkMuted
                    }
                    Text {
                        text: modelData.label
                        font.family: Theme.font; font.pixelSize: 14
                        font.weight: selected ? Font.DemiBold : Font.Normal
                        color: selected ? Theme.ink : Theme.inkMuted
                    }
                    Text {                                  // clipboard filter counts: ink-muted 12 px
                        visible: root.counts[modelData.key] !== undefined
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.counts[modelData.key] !== undefined ? String(root.counts[modelData.key]) : ""
                        font.family: Theme.font; font.pixelSize: 12
                        color: Theme.inkMuted
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: usable
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.picked(modelData.key)
                }
            }
        }
    }
}
