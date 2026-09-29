import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell.Widgets

// Enhalation desktop glass (docs/enhalation-desktop.md DP1–DP6), the same recipe as swaync's
// .control-center: the baked glass-grain tile IS the fill (glass-desktop + grain), a 165°
// sheen over it, the rim ring, a lit top edge, and glass-float below.
// `wash` lays a tint over the glass and replaces nothing under it (hover = pill-hover).
Item {
    id: root

    property real radius: Theme.radiusLg
    property color wash: "transparent"
    property color ring: Theme.rim
    property bool floating: true
    default property alias content: body.data

    Repeater {                                    // glass-float, one RectangularShadow per layer
        model: root.floating ? Theme.glassFloat : []
        RectangularShadow {
            required property var modelData
            anchors.fill: parent
            radius: root.radius
            offset: Qt.vector2d(modelData.x, modelData.y)
            blur: modelData.blur
            spread: modelData.spread
            color: modelData.color
        }
    }

    ClippingRectangle {
        anchors.fill: parent
        radius: root.radius
        color: "transparent"

        Image {                                   // fill + grain, 1:1 like swaync's 220px tile
            anchors.fill: parent
            source: "assets/glass-grain.png"
            fillMode: Image.Tile
            smooth: false
        }
        Rectangle {
            anchors.fill: parent
            color: root.wash
            Behavior on color {
                ColorAnimation {
                    duration: Theme.durHover
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.easeOutExpo
                }
            }
        }
        Shape {                                   // sheen: linear-gradient(165deg, tint, tint-end 42%)
            id: sheen
            anchors.fill: parent
            readonly property var line: Theme.gradientLine(165, width, height)
            ShapePath {
                strokeWidth: -1
                fillGradient: LinearGradient {
                    x1: sheen.line[0]; y1: sheen.line[1]; x2: sheen.line[2]; y2: sheen.line[3]
                    GradientStop { position: 0; color: Theme.tint }
                    GradientStop { position: 0.42; color: Theme.tintEnd }
                }
                startX: 0; startY: 0
                PathLine { x: sheen.width; y: 0 }
                PathLine { x: sheen.width; y: sheen.height }
                PathLine { x: 0; y: sheen.height }
                PathLine { x: 0; y: 0 }
            }
        }
        // The two inset shadows, in CSS order (the first listed paints on top), under the content.
        Rectangle {                               // rim: inset 0 0 0 1px
            anchors.fill: parent
            radius: root.radius
            color: "transparent"
            border.width: 1
            border.color: root.ring
        }
        Rectangle {                               // lit top edge: inset 0 1px 0 glass-edge.
            width: parent.width                   // Full width INSIDE the rounded clip, so the
            height: 1                             // corners trim it and it follows the curve
            color: Theme.glassEdge                // instead of overhanging the rim.
        }
        Item {
            id: body
            anchors.fill: parent
        }
    }
}
