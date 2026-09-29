import QtQuick
import QtQuick.Effects
import Quickshell.Widgets

// docs/capture-ui.md §3: Mode | shutter | Kind | Pointer | Close on glass (radius 26, padding
// 10). The glass is only the background, so the shutter's halo-glow is not clipped by it.
Item {
    id: bar

    property string mode: "area"
    property string kind: "photo"
    property bool pointer: false
    signal modePicked(string key)
    signal kindPicked(string key)
    signal pointerToggled()
    signal shoot()
    signal close()

    implicitWidth: row.implicitWidth + 20
    implicitHeight: row.implicitHeight + 20

    GlassPanel {
        anchors.fill: parent
        radius: Theme.radiusLg
    }

    component Label: Text {
        font.family: Theme.font
        font.pixelSize: 14
        color: Theme.ink
        verticalAlignment: Text.AlignVCenter
    }

    Row {
        id: row
        x: 10
        y: 10
        spacing: 12

        Segmented {
            anchors.verticalCenter: parent.verticalCenter
            current: bar.mode
            options: [
                { key: "area", glyph: Theme.gArea, label: "Area" },
                { key: "screen", glyph: Theme.gScreen, label: "Screen" },
                { key: "window", glyph: Theme.gWindow, label: "Window" }
            ]
            onPicked: (key) => bar.modePicked(key)
        }

        Item {                                  // shutter: the warm core, 60 px
            id: shutter
            width: 60
            height: 60
            anchors.verticalCenter: parent.verticalCenter
            scale: shutterArea.pressed ? 0.972 : 1
            Behavior on scale { NumberAnimation { duration: Theme.durPress; easing.type: Easing.BezierSpline; easing.bezierCurve: Theme.easePress } }
            Repeater {                          // halo-glow, halo-glow-lift on hover
                model: shutterArea.containsMouse ? Theme.haloGlowLift : Theme.haloGlow
                RectangularShadow {
                    required property var modelData
                    anchors.fill: parent
                    radius: 30
                    offset: Qt.vector2d(modelData.x, modelData.y)
                    blur: modelData.blur
                    spread: modelData.spread
                    color: modelData.color
                }
            }
            Image {
                anchors.fill: parent
                source: "assets/shutter-60.png"
                smooth: false
            }
            Label {
                anchors.centerIn: parent
                text: bar.kind === "video" ? Theme.gRecord : Theme.gCamera
                font.pixelSize: 22
                color: Theme.onHalo
            }
            MouseArea {
                id: shutterArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.shoot()
            }
        }

        Segmented {
            anchors.verticalCenter: parent.verticalCenter
            current: bar.kind
            options: [
                { key: "photo", glyph: Theme.gPhoto, label: "Photo" },
                { key: "video", glyph: Theme.gVideo, label: "Video" }
            ]
            onPicked: (key) => bar.kindPicked(key)
        }

        Rectangle {                             // Pointer: ghost button, ON = pill + accent glyph
            id: pointerButton
            readonly property bool on: bar.pointer || bar.kind === "video"
            readonly property bool usable: bar.kind !== "video"     // Video: always recorded
            anchors.verticalCenter: parent.verticalCenter
            width: pointerRow.implicitWidth + 28
            height: 40
            radius: Theme.radiusSm
            color: on ? Theme.pill : (pointerArea.containsMouse ? Theme.pill : "transparent")
            opacity: usable ? 1 : Theme.opacityDisabled
            Behavior on color { ColorAnimation { duration: Theme.durHover } }
            Row {
                id: pointerRow
                anchors.centerIn: parent
                spacing: 8
                Label { text: Theme.gPointer; color: pointerButton.on ? Theme.accent : Theme.inkMuted }
                Label { text: "Pointer"; color: pointerButton.on ? Theme.ink : Theme.inkMuted }
            }
            MouseArea {
                id: pointerArea
                anchors.fill: parent
                enabled: pointerButton.usable
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.pointerToggled()
            }
        }

        Rectangle {                             // Close: 40 px glass circle
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            height: 40
            radius: 20
            color: closeArea.containsMouse ? Theme.pillHover : Theme.pill
            Behavior on color { ColorAnimation { duration: Theme.durHover } }
            Label { anchors.centerIn: parent; text: Theme.gClose }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.close()
            }
        }
    }
}
