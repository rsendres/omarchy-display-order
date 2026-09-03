# Omarchy Display Order

Drag-and-drop display ordering for Omarchy. Arrange your monitors visually and keep Hyprland display layout and scaling in sync.

## What it does

Omarchy Display Order adds numbering and drag-and-drop ordering to Omarchy's **Displays** section. For example:

```text
1 Monitor 1
2 Monitor 2
```

Dragging a row changes the logical left-to-right arrangement in Hyprland. For example:

```text
Before:
1 Monitor 1
2 Monitor 2

After dragging Monitor 2 upward:
1 Monitor 2
2 Monitor 1
```

- Drag-and-drop display ordering
- Hover-to-identify physical displays
- Automatic logical positioning
- Scale-aware layout calculations
- Persistence across reboot
- Reload-safe monitor configuration
- Support for one, two, or three or more monitors

## Screenshots

Screenshots will be added here.

## Requirements

- Omarchy 4.0.1-1, using its shell plugin system and `omarchy plugin` commands
- Hyprland 0.56.2
- `hyprctl`, `jq`, `flock`, and `luac` (provided by the development installation)

These are the versions and features used during development and validation. Compatibility with other Omarchy or Hyprland versions has not been tested.

## Installation

Install with Omarchy's official plugin mechanism:

```bash
omarchy plugin add https://github.com/rsendres/omarchy-display-order.git --enable
```


## Usage

Open **Setup → Display**. In **DISPLAYS**, drag the numbered monitor rows into the desired order.

The first row becomes the leftmost logical display in Hyprland, followed by the remaining rows from left to right.

When displays are explicitly reordered and their active workspaces are exactly the default numeric set `1..N`, the plugin renumbers those workspace IDs to match the new display slots. This does not move workspaces, windows, or clients between physical outputs. Custom, named, mixed, and special workspaces are left untouched; only the display geometry changes.

### Identify a display

Park the mouse pointer over a monitor row for two seconds to print its current
list number on that physical display, in the upper-left corner. The identifier
remains visible while the pointer stays on the row, disappears immediately on
exit, and is disabled during drag-and-drop. It uses the Hyprland output name
(for example, `DP-2` or `HDMI-A-1`) to select the matching physical display.

## How it works

- `order.json` is the source of the preferred monitor order.
- Hyprland receives a layout with `0x0` for the first monitor and `auto-right` for each following monitor.
- Logical widths account for each monitor's scale and rotation.
- Scale presets are reduced to the nearest mode-valid `1/120` unit. The UI presents the effective value to two decimal places, while the generated monitor configuration preserves six significant digits.
- A managed block in `monitors.lua` makes reloads safe.
- `Service.qml` restores the saved display order/layout during startup. The plugin neither imposes workspace numbers nor creates or permanently manages workspaces.

## Uninstall / rollback

If the managed monitor block should be removed before uninstalling, run:

```bash
scripts/reorder-displays --remove-config-block
```

When the plugin rewrites `~/.config/hypr/monitors.lua`, it keeps the five newest plugin-owned timestamped backups alongside the file. Backups created by other tools are not managed.

Then remove the plugin through Omarchy:

```bash
omarchy plugin remove omarchy-display-order.display-order
```

## Known limitations

- Advanced automatic hotplug handling has not been implemented yet.

## Development

Run these checks from the plugin root:

```bash
bash -n scripts/reorder-displays
tests/test_reorder_displays.sh
tests/test_scale_normalization.sh
luac -p "$HOME/.config/hypr/monitors.lua"
git diff --check
omarchy plugin validate .
```

If `qmlformat` is installed, format or validate the QML files before committing:

```bash
qmlformat -i Panel.qml Service.qml
```
