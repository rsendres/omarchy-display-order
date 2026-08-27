function clampBrightness(value) {
  var n = Number(value)
  if (!isFinite(n)) return 1
  return Math.max(1, Math.min(100, Math.round(n)))
}

function normalizeScale(scale) {
  var n = parseFloat(String(scale || ""))
  if (!isFinite(n)) return ""
  return String(Math.round(n * 100) / 100)
}

function gcd(a, b) {
  while (b) {
    var remainder = a % b
    a = b
    b = remainder
  }
  return a
}

function cleanScale(scale, width, height) {
  var requested = Number(scale)
  var modeWidth = Number(width)
  var modeHeight = Number(height)
  if (!isFinite(requested) || !isFinite(modeWidth) || !isFinite(modeHeight)
      || requested <= 0 || modeWidth <= 0 || modeHeight <= 0) return ""

  var divisor = gcd(Math.round(modeWidth * 120), Math.round(modeHeight * 120))
  var scaleUnits = Math.round(requested * 120)
  if (scaleUnits > divisor) scaleUnits = divisor
  while (divisor % scaleUnits !== 0) scaleUnits++
  return normalizeScale(scaleUnits / 120)
}

function matchingScaleIndex(scales, currentScale, width, height) {
  var current = Number(currentScale)
  if (!Array.isArray(scales) || !isFinite(current)) return -1

  var bestIndex = -1
  var bestDistance = Infinity
  var normalizedCurrent = normalizeScale(current)
  for (var i = 0; i < scales.length; i++) {
    if (cleanScale(scales[i], width, height) !== normalizedCurrent) continue

    var distance = Math.abs(Number(scales[i]) - current)
    if (distance < bestDistance) {
      bestIndex = i
      bestDistance = distance
    }
  }
  return bestIndex
}

function availableScales(scales, width, height) {
  if (!Array.isArray(scales) || Number(width) <= 0 || Number(height) <= 0) return scales || []

  var byEffectiveScale = {}
  for (var i = 0; i < scales.length; i++) {
    var requested = Number(scales[i])
    var effective = Number(cleanScale(requested, width, height))

    if (!isFinite(requested) || !isFinite(effective)) continue

    var key = normalizeScale(effective)
    var existing = byEffectiveScale[key]
    if (!existing || Math.abs(requested - effective) < existing.distance) {
      byEffectiveScale[key] = {
        value: String(scales[i]),
        index: i,
        distance: Math.abs(requested - effective)
      }
    }
  }

  return Object.keys(byEffectiveScale)
    .map(function(key) { return byEffectiveScale[key] })
    .sort(function(a, b) { return a.index - b.index })
    .map(function(candidate) { return candidate.value })
}

function brightnessName(percent) {
  var p = Math.round(percent)
  if (p >= 95) return "Sun blast"
  if (p >= 80) return "Solar flare"
  if (p >= 65) return "Golden hour"
  if (p >= 45) return "Even day"
  if (p >= 30) return "Soft glow"
  if (p >= 20) return "Lamp light"
  if (p >= 10) return "Candlelit"
  return "Night owl"
}

function monitorDetailsByName(raw) {
  var monitors = []
  try {
    monitors = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    monitors = []
  }
  if (!Array.isArray(monitors)) monitors = []

  var details = {}
  for (var i = 0; i < monitors.length; i++) {
    var monitor = monitors[i]
    if (monitor && monitor.name) details[monitor.name] = monitor
  }
  return details
}

function horizontalDisplayOrder(displays) {
  if (!Array.isArray(displays)) return []

  // Hyprland reports positions in logical coordinates. Put an unavailable
  // position (for example during a compositor restart) after known positions;
  // use the name as a deterministic tie-breaker.
  return displays.slice().sort(function(a, b) {
    var ax = Number(a && a.x)
    var bx = Number(b && b.x)
    var aHasX = isFinite(ax)
    var bHasX = isFinite(bx)
    if (aHasX && bHasX && ax !== bx) return ax - bx
    if (aHasX !== bHasX) return aHasX ? -1 : 1
    var aName = String((a && a.name) || "")
    var bName = String((b && b.name) || "")
    return aName < bName ? -1 : (aName > bName ? 1 : 0)
  })
}

function parseDisplays(raw, monitorDetailsRaw) {
  var displays = []
  try {
    displays = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    displays = []
  }
  if (!Array.isArray(displays)) displays = []

  var details = monitorDetailsByName(monitorDetailsRaw)
  for (var j = 0; j < displays.length; j++) {
    var display = displays[j]
    var monitor = display && details[display.name]
    if (!monitor) continue

    // Retain the state helper's enabled/focused values, but attach the layout
    // facts required to show Hyprland's real horizontal order.
    display.x = monitor.x
    display.y = monitor.y
    display.scale = monitor.scale
    display.transform = monitor.transform
    display.refreshRate = monitor.refreshRate
    display.disabled = monitor.disabled
    display.mirrorOf = monitor.mirrorOf
  }
  displays = horizontalDisplayOrder(displays)

  var count = 0
  for (var i = 0; i < displays.length; i++) {
    if (displays[i] && displays[i].enabled) count++
  }

  return {
    displays: displays,
    enabledDisplayCount: count
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    clampBrightness: clampBrightness,
    normalizeScale: normalizeScale,
    cleanScale: cleanScale,
    matchingScaleIndex: matchingScaleIndex,
    availableScales: availableScales,
    brightnessName: brightnessName,
    monitorDetailsByName: monitorDetailsByName,
    horizontalDisplayOrder: horizontalDisplayOrder,
    parseDisplays: parseDisplays
  }
}
