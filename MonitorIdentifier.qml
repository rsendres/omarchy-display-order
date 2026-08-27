import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons

Variants {
  id: identifiers
  property string targetOutput: ""
  property int ordinal: 0
  property bool identifyVisible: false
  model: Quickshell.screens

  PanelWindow {
    required property var modelData
    readonly property int pad: Math.max(Style.space(10),
      Math.round(Style.font.display * 0.35))

    screen: modelData
    visible: identifiers.identifyVisible && modelData
      && modelData.name === identifiers.targetOutput
    color: "transparent"
    implicitWidth: badge.width
    implicitHeight: badge.height

    anchors.top: true
    anchors.left: true
    margins.top: Style.space(24)
    margins.left: Style.space(24)

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: badge
      width: borderLeft + pad + numberLabel.implicitWidth + pad + borderRight
      height: borderTop + pad + numberLabel.implicitHeight + pad + borderBottom
      anchors.top: parent.top
      anchors.left: parent.left
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border,
        Math.max(1, Style.space(2)))
      radius: Style.cornerRadius

      Text {
        id: numberLabel
        anchors.centerIn: parent
        text: String(identifiers.ordinal)
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.display * 1.25)
        font.bold: true
      }
    }
  }
}
