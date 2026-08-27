import QtQuick
import Quickshell
import Quickshell.Io

// Headless startup companion for the display panel. It owns no configuration:
// it merely asks the helper to recalculate a previously saved *order* using
// Hyprland's current mode, scale, transform and connected outputs.
Item {
  id: root

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string orderFile: stateHome + "/omarchy/omarchy-display-order.display-order/order.json"
  readonly property string reorderDisplaysHelper: Qt.resolvedUrl("scripts/reorder-displays").toString().replace("file://", "")
  readonly property int maxSocketAttempts: 4
  property int socketAttempts: 0

  function startApplySaved() {
    if (applySavedProc.running) return
    socketAttempts += 1
    applySavedProc.command = [reorderDisplaysHelper, "--apply-saved"]
    applySavedProc.running = true
  }

  // Do not invoke the helper at all until a user has saved an order. This also
  // makes a first installation a no-op rather than an output reconfiguration.
  Component.onCompleted: {
    if (!Quickshell.env("HOME") && !Quickshell.env("XDG_STATE_HOME")) {
      console.warn("omarchy-display-order.display-order service: no XDG_STATE_HOME or HOME; saved order is unavailable")
      return
    }
    orderProbe.command = ["test", "-r", orderFile]
    orderProbe.running = true
  }

  Process {
    id: orderProbe
    onExited: function(exitCode) {
      if (exitCode === 0) root.startApplySaved()
    }
  }

  Process {
    id: applySavedProc
    stdout: StdioCollector { id: applySavedOutput; waitForEnd: true }
    stderr: StdioCollector { id: applySavedError; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(applySavedOutput.text || "").trim()
      var stderr = String(applySavedError.text || "").trim()
      if (exitCode === 0) {
        if (stderr !== "") {
          console.warn("omarchy-display-order.display-order: --apply-saved completed with diagnostics\n"
            + stderr)
        }
        return
      }

      // At shell startup Hyprland's IPC socket can briefly be unavailable, or
      // another helper can briefly hold the advisory lock. Retry only those
      // identifiable transient failures, at a calm fixed delay.
      var socketUnavailable = stderr.indexOf("could not query Hyprland monitors") !== -1
      var lockBusy = stderr.indexOf("another display reorder is already in progress") !== -1
      if ((socketUnavailable || lockBusy) && root.socketAttempts < root.maxSocketAttempts) {
        startupRetry.restart()
        return
      }
      console.warn("omarchy-display-order.display-order service: saved display order was not applied (exit " + exitCode
        + ")\nstdout: " + stdout + "\nstderr: " + stderr)
    }
  }

  Timer {
    id: startupRetry
    interval: 700
    repeat: false
    onTriggered: root.startApplySaved()
  }
}
