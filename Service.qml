import QtQuick
import Quickshell
import Quickshell.Io

// Headless startup companion for the display panel. It owns no configuration:
// it merely asks the helper to recalculate a previously saved *order* using
// Hyprland's current mode, scale, transform and connected outputs.
Item {
  id: root

  readonly property string reorderDisplaysHelper: Qt.resolvedUrl("scripts/reorder-displays").toString().replace("file://", "")

  function startStartupApplySaved() {
    if (startupApplySavedProc.running) return
    startupApplySavedProc.command = [reorderDisplaysHelper, "--startup-apply-saved"]
    startupApplySavedProc.running = true
  }

  // Do not invoke the helper at all until a user has saved an order. This also
  // makes a first installation a no-op rather than an output reconfiguration.
  Component.onCompleted: {
    if (!Quickshell.env("HOME") && !Quickshell.env("XDG_STATE_HOME")) {
      console.warn("omarchy-display-order.display-order service: no XDG_STATE_HOME or HOME; saved order is unavailable")
      return
    }
    root.startStartupApplySaved()
  }

  Process {
    id: startupApplySavedProc
    stdout: StdioCollector { id: startupApplySavedOutput; waitForEnd: true }
    stderr: StdioCollector { id: startupApplySavedError; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(startupApplySavedOutput.text || "").trim()
      var stderr = String(startupApplySavedError.text || "").trim()
      if (exitCode === 0) {
        if (stderr !== "") {
          console.warn("omarchy-display-order.display-order: --startup-apply-saved completed with diagnostics\n"
            + stderr)
        }
        return
      }

      // The helper owns the single startup claim and retries transient IPC/lock
      // contention before recording a terminal result.
      console.warn("omarchy-display-order.display-order service: saved display order was not applied (exit " + exitCode
        + ")\nstdout: " + stdout + "\nstderr: " + stderr)
    }
  }
}
