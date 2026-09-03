import QtQuick
import QtQuick.Controls
import QtQml.Models
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string focusedMonitor: ""
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0
  property bool displayReorderApplying: false
  property bool displayDragActive: false
  property var displaysBeforeLiveReorder: []
  property string displayReorderError: ""
  property string queuedScale: ""
  property bool actionIsScale: false
  readonly property bool actionProcessRunning: actionProc.running
  property string monitorIdentifyTarget: ""
  property var monitorIdentifyDisplay: null
  property int monitorIdentifyOrdinal: 0
  property bool monitorIdentifyVisible: false
  property bool refreshPending: false
  property bool brightnessRefreshPending: false
  property int stateRefreshRetries: 0
  property int brightnessRefreshRetries: 0
  readonly property int maxRefreshRetries: 3
  readonly property string reorderDisplaysHelper: Qt.resolvedUrl("scripts/reorder-displays").toString().replace("file://", "")

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (root.displayDragActive || root.displayReorderApplying || root.actionProcessRunning) {
      root.refreshPending = true
      return
    }
    if (stateProc.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    stateProc.running = true
  }

  function refreshBrightness() {
    if (!root.focusedMonitor) return
    if (brightnessProc.running) {
      root.brightnessRefreshPending = true
      return
    }
    root.brightnessRefreshPending = false
    brightnessProc.command = ["omarchy-brightness-display", "--monitor", root.focusedMonitor]
    brightnessProc.running = true
  }

  function applyMonitorState(raw) {
    var monitors = []
    try {
      monitors = JSON.parse(String(raw || ""))
    } catch (e) {
      return false
    }
    if (!Array.isArray(monitors) || monitors.length === 0) return false

    var focused = null
    var displaySummary = []
    for (var i = 0; i < monitors.length; i++) {
      var monitor = monitors[i]
      if (!monitor || !monitor.name) return false
      if (monitor.focused === true) focused = monitor
      displaySummary.push({
        name: monitor.name,
        enabled: monitor.disabled !== true,
        disabled: monitor.disabled === true,
        mirrorOf: monitor.mirrorOf || "",
        focused: monitor.focused === true,
        width: monitor.width,
        height: monitor.height
      })
    }
    // A missing focused monitor is transient during an output reconfiguration.
    // Keep the last complete state instead of replacing it with an empty panel.
    if (!focused || !focused.name) return false

    var nextFocusedMonitor = String(focused.name)
    var focusedMonitorChanged = root.focusedMonitor !== nextFocusedMonitor
    root.focusedMonitor = nextFocusedMonitor
    root.monitorScale = root.normalizeScale(focused.scale)
    root.updateDisplays(JSON.stringify(displaySummary), JSON.stringify(monitors))
    if (focusedMonitorChanged) root.refreshBrightness()
    return true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson, monitorDetailsJson) {
    var parsed = Model.parseDisplays(displaysJson, monitorDetailsJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  // DelegateModel owns the live visual order while dragging. Invoke the helper
  // only after drop; the panel supplies names/order, never coordinates.
  function isDisplayReorderEligible(display) {
    if (!display || !display.enabled || display.disabled === true) return false
    return display.mirrorOf === undefined || display.mirrorOf === null
      || display.mirrorOf === "" || display.mirrorOf === "none"
  }

  function consumePendingDisplayRefresh() {
    if (root.refreshPending) root.refresh()
  }

  function cancelMonitorIdentify() {
    monitorIdentifyTimer.stop()
    root.monitorIdentifyVisible = false
    root.monitorIdentifyTarget = ""
    root.monitorIdentifyDisplay = null
    root.monitorIdentifyOrdinal = 0
  }

  function cancelMonitorIdentifyFor(display) {
    if (display && display === root.monitorIdentifyDisplay)
      root.cancelMonitorIdentify()
  }

  function reconcileMonitorIdentify() {
    if (root.monitorIdentifyTarget === "") return
    if (root.displayDragActive || root.displayReorderApplying || root.actionProcessRunning) {
      root.cancelMonitorIdentify()
      return
    }
    for (var i = 0; i < root.displays.length; i++) {
      var display = root.displays[i]
      if (display && String(display.name) === root.monitorIdentifyTarget
          && root.isDisplayReorderEligible(display)) {
        root.monitorIdentifyOrdinal = i + 1
        root.monitorIdentifyDisplay = display
        return
      }
    }
    root.cancelMonitorIdentify()
  }

  function startMonitorIdentify(display, ordinal) {
    if (!root.opened || root.displayDragActive || root.displayReorderApplying
        || root.actionProcessRunning || !root.isDisplayReorderEligible(display)) {
      root.cancelMonitorIdentifyFor(display)
      return
    }
    if (!display.name || ordinal < 1) return
    if (root.monitorIdentifyTarget !== String(display.name))
      root.cancelMonitorIdentify()
    root.monitorIdentifyTarget = String(display.name)
    root.monitorIdentifyDisplay = display
    root.monitorIdentifyOrdinal = ordinal
    if (!root.monitorIdentifyVisible && !monitorIdentifyTimer.running)
      monitorIdentifyTimer.restart()
  }

  Timer {
    id: monitorIdentifyTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!root.opened || root.displayDragActive || root.displayReorderApplying
          || root.actionProcessRunning || root.monitorIdentifyTarget === "") {
        root.cancelMonitorIdentify()
        return
      }
      var stillPresent = false
      for (var i = 0; i < root.displays.length; i++) {
        if (String(root.displays[i].name) === root.monitorIdentifyTarget
            && root.isDisplayReorderEligible(root.displays[i])) {
          stillPresent = true
          break
        }
      }
      if (stillPresent) root.monitorIdentifyVisible = true
      else root.cancelMonitorIdentify()
    }
  }

  function applyVisualDisplayOrder() {
    if (displayReorderApplying) return
    if (root.actionProcessRunning) {
      root.displays = root.displays.slice()
      root.refreshPending = true
      return
    }
    var reordered = []
    var eligible = []
    for (var i = 0; i < displayList.count; i++) {
      var item = displayList.itemAtIndex(i)
      if (item && item.display) {
        reordered.push(item.display)
        if (root.isDisplayReorderEligible(item.display)) eligible.push(item.display)
      }
    }
    if (reordered.length !== root.displays.length) {
      root.displays = root.displays.slice()
      root.consumePendingDisplayRefresh()
      return
    }
    if (eligible.length === 0) {
      root.displays = root.displays.slice()
      root.consumePendingDisplayRefresh()
      return
    }

    var currentEligible = root.displays.filter(function(display) {
      return root.isDisplayReorderEligible(display)
    })
    var unchanged = eligible.length === currentEligible.length
    for (var j = 0; unchanged && j < eligible.length; j++)
      unchanged = String(eligible[j].name) === String(currentEligible[j].name)
    if (unchanged) {
      root.displays = root.displays.slice()
      root.consumePendingDisplayRefresh()
      return
    }

    displaysBeforeLiveReorder = root.displays.slice()
    var pendingDisplayOrder = eligible.map(function(display) {
      return String(display.name)
    })
    root.cancelMonitorIdentify()
    displayReorderError = ""
    displayReorderApplying = true
    root.displays = reordered
    reorderProc.command = [reorderDisplaysHelper, "--apply-and-save"].concat(pendingDisplayOrder)
    reorderProc.running = true
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (root.displayReorderApplying || root.displayDragActive || root.actionProcessRunning) return
    if (enabled && root.enabledDisplayCount <= 1) return
    if (actionProc.running) return

    root.cancelMonitorIdentify()
    actionIsScale = false
    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    actionProc.running = true
  }

  function setScale(scale) {
    if (root.displayReorderApplying || root.displayDragActive) return
    root.cancelMonitorIdentify()
    if (actionProc.running) {
      // A running CLI cannot be changed in place. Keep only the newest click;
      root.queuedScale = String(scale)
      return
    }
    root.startScaleChange(String(scale))
  }

  function startScaleChange(scale) {
    root.actionIsScale = true
    actionProc.command = [root.reorderDisplaysHelper, "--set-scale", scale]
    actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()
  Component.onDestruction: cancelMonitorIdentify()

  MonitorIdentifier {
    targetOutput: root.monitorIdentifyTarget
    ordinal: root.monitorIdentifyOrdinal
    identifyVisible: root.monitorIdentifyVisible
  }

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      refreshBrightness()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    } else root.cancelMonitorIdentify()
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: {
    root.reconcileMonitorIdentify()
    clampCursor()
  }
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: stateRefreshRetry
    interval: 150
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: brightnessRefreshRetry
    interval: 200
    repeat: false
    onTriggered: root.refreshBrightness()
  }

  Timer {
    id: brightnessRefreshFallback
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.refreshBrightness()
  }

  Process {
    id: stateProc
    // Monitor metadata is fast and must not wait on DDC brightness I/O.
    command: ["hyprctl", "-j", "monitors", "all"]
    stdout: StdioCollector { id: stateOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var valid = false
      if (root.displayDragActive || root.displayReorderApplying || root.actionProcessRunning) {
        root.refreshPending = true
      } else {
        valid = exitCode === 0 && root.applyMonitorState(stateOutput.text)
      }
      if (valid) {
        root.stateRefreshRetries = 0
      } else if (root.stateRefreshRetries < root.maxRefreshRetries) {
        root.stateRefreshRetries += 1
        stateRefreshRetry.restart()
      }

      if (root.refreshPending) root.refresh()
    }
  }

  Process {
    id: brightnessProc
    stdout: StdioCollector { id: brightnessOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var text = String(brightnessOutput.text || "").trim()
      var value = parseInt(text, 10)
      var valid = exitCode === 0 && /^\d+$/.test(text) && value >= 0 && value <= 100
      if (valid) {
        root.brightnessAvailable = true
        root.brightnessPercent = value
        root.brightnessRefreshRetries = 0
      } else if (!root.brightnessAvailable && root.brightnessRefreshRetries < root.maxRefreshRetries) {
        root.brightnessRefreshRetries += 1
        brightnessRefreshRetry.restart()
      }

      if (root.brightnessRefreshPending) root.refreshBrightness()
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionErrorOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var stderr = String(actionErrorOutput.text || "").trim()
      if (root.queuedScale !== "") {
        var nextScale = root.queuedScale
        root.queuedScale = ""
        root.startScaleChange(nextScale)
        return
      }
      if (!root.actionIsScale) {
        root.refresh()
        return
      }
      if (exitCode !== 0) {
        console.warn("omarchy-display-order.display-order: scale change failed (exit " + exitCode + ")\nstderr: " + stderr)
        root.refresh()
        return
      }
      root.refresh()
    }
  }

  Process {
    id: reorderProc
    stdout: StdioCollector { id: reorderOutput; waitForEnd: true }
    stderr: StdioCollector { id: reorderErrorOutput; waitForEnd: true }
    onExited: function(exitCode) {
      var stdout = String(reorderOutput.text || "").trim()
      var stderr = String(reorderErrorOutput.text || "").trim()
      if (exitCode !== 0) {
        root.cancelMonitorIdentify()
        root.displayReorderApplying = false
        root.displays = root.displaysBeforeLiveReorder.slice()
        var detail = stderr || stdout
        root.displayReorderError = detail !== "" ? detail : "Could not apply display order"
        console.warn("omarchy-display-order.display-order: display reorder failed (exit " + exitCode
          + ")\nstdout: " + stdout + "\nstderr: " + stderr)
        root.refresh()
        return
      }
      console.log("omarchy-display-order.display-order: display reorder completed (exit " + exitCode
        + ")\nstdout: " + stdout + "\nstderr: " + stderr)
      root.cancelMonitorIdentify()
      root.displayReorderApplying = false
      root.refresh()
    }
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Display"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "FIXED BRIGHTNESS"
                }
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Brightness ----------
          PanelSeparator {
            visible: root.brightnessAvailable
            foreground: root.bar.foreground
          }

          Column {
            visible: root.brightnessAvailable
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

              PanelSectionHeader {
                id: brightnessHeader
                text: "BRIGHTNESS"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: brightnessPercent
                text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: brightnessRow
              width: parent.width
              height: brightnessSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: brightnessSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 1
                maximum: 100
                step: 1
                value: root.brightnessPercent
                integer: true
                onMoved: function(v) { root.previewBrightness(v) }
                onReleased: function(v) {
                  brightnessDebounce.stop()
                  root.setBrightness(v)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "brightness"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Text size ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

              PanelSectionHeader {
                id: textSizeHeader
                text: "TEXT SIZE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: textSizePx
                text: (textSizeSlider.dragging
                       ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                       : root.displayedTextPx()) + "px"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: textSizeRow
              width: parent.width
              height: textSizeSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: textSizeSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.textSizeStops.length - 1
                step: 1
                integer: true
                tickCount: root.textSizeStops.length
                value: root.currentTextIndex()
                onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered && !root.reflowingText) {
                  root.cursorActive = true
                  root.focusSection = "textsize"
                  root.selectedIndex = -1
                }
              }
            }
          }

          // ---------- Scale ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

              PanelSectionHeader {
                id: scaleHeader
                text: "SCALE"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Name the monitor SCALE targets, since it only applies to the
              // focused one.
              Text {
                id: scaleMonitor
                text: root.focusedMonitor
                // Only worth naming when more than one display is in play.
                visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Grid {
              id: scaleRow
              width: parent.width
              columns: root.scaleValues.length
              spacing: Style.spacing.xs

              readonly property real cellWidth: root.scaleValues.length > 0
                ? (width - spacing * (columns - 1)) / columns
                : 0

              Repeater {
                model: root.scaleValues

                ScalePill {
                  required property string modelData
                  required property int index

                  scaleValue: modelData
                  scaleIndex: index
                  width: scaleRow.cellWidth
                }
              }
            }
          }

          // ---------- Monitors ----------
          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displays.length > 1

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ListView {
              id: displayList
              width: parent.width
              height: contentHeight
              implicitHeight: contentHeight
              spacing: Style.space(10)
              interactive: false
              clip: false
              model: displayVisualModel

              // Only displaced rows animate. The item under the pointer uses
              // its own direct position and therefore never trails the mouse.
              moveDisplaced: Transition {
                NumberAnimation {
                  properties: "y"
                  duration: 150
                  easing.type: Easing.OutCubic
                }
              }
            }

            Text {
              visible: root.displayReorderError !== ""
              width: parent.width
              text: "REORDER FAILED · " + root.displayReorderError
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    enabled: !root.displayReorderApplying && !root.displayDragActive
    opacity: enabled ? 1.0 : 0.45

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  DelegateModel {
    id: displayVisualModel
    model: root.displays

    delegate: MonitorRow {
      required property var modelData
      width: displayList.width
      display: modelData
      rowIndex: DelegateModel.itemsIndex
    }
  }

  component MonitorRow: Item {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)
    property bool dragging: false
    property bool wasDragged: false
    property real dragCenterY: 0
    property real pointerOffsetY: 0
    readonly property bool canReorder: root.isDisplayReorderEligible(display)

    implicitHeight: rowSurface.implicitHeight
    z: dragging ? 1 : 0

    CursorSurface {
      id: rowSurface
      width: parent.width
      y: monitorRow.dragging
        ? monitorRow.dragCenterY - monitorRow.y - height / 2
        : 0
      hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === monitorRow.rowIndex
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
      current: monitorRow.isFocused || monitorRow.dragging
      foreground: root.bar.foreground
      fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
      currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
      implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
      opacity: root.displayReorderApplying ? 0.55
        : (monitorRow.canReorder || monitorRow.canToggle ? (monitorRow.dragging ? 0.92 : 1.0) : 0.45)

      // On drop, return the row to the ListView slot without a hard snap.
      Behavior on y {
        enabled: !monitorRow.dragging
        NumberAnimation {
          duration: 150
          easing.type: Easing.OutCubic
        }
      }

      Row {
        id: monitorInner
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(8)

        Text {
          text: String(monitorRow.rowIndex + 1)
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(12)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "󰍹"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: monitorRow.display.name + (monitorRow.display.focused ? " · focused" : "")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width - Style.space(12) - Style.space(22) - Style.space(14) - Style.space(24)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: monitorRow.display.enabled ? "󰄬" : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          width: Style.space(14)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: !root.displayReorderApplying && !root.actionProcessRunning
        hoverEnabled: true
        cursorShape: monitorRow.dragging ? Qt.ClosedHandCursor
          : (monitorRow.canReorder || monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor)
        onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
          root.cursorActive = true
          root.focusSection = "monitors"
          root.selectedIndex = monitorRow.rowIndex
          root.startMonitorIdentify(monitorRow.display, monitorRow.rowIndex + 1)
        } else if (!containsMouse) root.cancelMonitorIdentifyFor(monitorRow.display)
        property real pressY: 0

        onPressed: function(mouse) {
          root.cancelMonitorIdentify()
          root.displayDragActive = true
          pressY = mouse.y
          monitorRow.dragging = false
          monitorRow.wasDragged = false
          monitorRow.pointerOffsetY = mouse.y
          root.displayReorderError = ""
        }
        onPositionChanged: function(mouse) {
          if (!pressed) return
          if (!monitorRow.dragging && monitorRow.canReorder
              && Math.abs(mouse.y - pressY) >= Style.space(6)) {
            root.cancelMonitorIdentify()
            var initialPoint = rowSurface.mapToItem(displayList.contentItem, mouse.x, mouse.y)
            monitorRow.dragCenterY = initialPoint.y - monitorRow.pointerOffsetY + rowSurface.height / 2
            monitorRow.dragging = true
            root.displayDragActive = true
          }
          if (!monitorRow.dragging) return

          var point = rowSurface.mapToItem(displayList.contentItem, mouse.x, mouse.y)
          monitorRow.dragCenterY = point.y - monitorRow.pointerOffsetY + rowSurface.height / 2

          // Move only after the dragged row's center crosses a neighbour's
          // center. This creates a stable threshold around each boundary.
          var fromIndex = monitorRow.rowIndex
          var targetIndex = fromIndex
          // Compare with the delegate's ListView slot, not rowSurface.y:
          // rowSurface.y follows dragCenterY and would make the downward
          // comparison tautological (dragCenterY > dragCenterY).
          if (monitorRow.dragCenterY > monitorRow.y + rowSurface.height / 2) {
            for (var down = fromIndex + 1; down < displayList.count; down++) {
              var lower = displayList.itemAtIndex(down)
              if (lower && monitorRow.dragCenterY > lower.y + lower.height / 2) targetIndex = down
              else break
            }
          } else {
            for (var up = fromIndex - 1; up >= 0; up--) {
              var upper = displayList.itemAtIndex(up)
              if (upper && monitorRow.dragCenterY < upper.y + upper.height / 2) targetIndex = up
              else break
            }
          }
          if (targetIndex !== fromIndex) displayVisualModel.items.move(fromIndex, targetIndex)
        }
        onReleased: {
          root.cancelMonitorIdentify()
          monitorRow.wasDragged = monitorRow.dragging
          monitorRow.dragging = false
          root.displayDragActive = false
          if (monitorRow.wasDragged) root.applyVisualDisplayOrder()
          else root.consumePendingDisplayRefresh()
        }
        onCanceled: {
          root.cancelMonitorIdentify()
          monitorRow.dragging = false
          root.displayDragActive = false
          root.displays = root.displays.slice()
          root.consumePendingDisplayRefresh()
        }
        onClicked: {
          if (!monitorRow.wasDragged && monitorRow.canToggle)
            root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
          monitorRow.wasDragged = false
        }
      }
    }
  }
}
