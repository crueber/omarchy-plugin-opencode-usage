import QtQuick

// The OpenCode mark, drawn from the official 512×512 geometry: a square frame
// with a block rising from the bottom of the opening. Drawing it in QML keeps
// it crisp at bar sizes and lets it follow the theme foreground instead of
// shipping a fixed-colour bitmap. The official aspect is 256×320 (0.8).
Item {
  id: root

  property real markSize: 16
  property color color: "white"
  // The official mark's inner block is grey rather than the frame colour. A
  // translucent version of the foreground reproduces that on both dark and
  // light themes without a second hard-coded colour.
  property color blockColor: Qt.rgba(color.r, color.g, color.b, 0.45)

  readonly property real stroke: Math.max(1, Math.round(markSize * 0.2))

  implicitWidth: Math.round(markSize * 0.8)
  implicitHeight: markSize
  width: implicitWidth
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    color: "transparent"
    border.width: root.stroke
    border.color: root.color
  }

  Rectangle {
    width: parent.width - root.stroke * 2
    height: Math.round(width)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: root.stroke
    color: root.blockColor
  }
}
