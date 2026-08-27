# Omarchy Display Order

Drag-and-drop display ordering for Omarchy. Arrange your monitors visually and keep Hyprland workspaces, scaling, and layout in sync.

## What it does

Omarchy Display Order adds numbering and drag-and-drop ordering to Omarchy's **Displays** section. For example:

```text
1 Monitor A
2 Monitor B
```

Dragging a row changes the logical left-to-right arrangement in Hyprland. For example:

```text
Before:
1 Monitor A
2 Monitor B

After dragging Monitor B upward:
1 Monitor B
2 Monitor A
```

- Drag-and-drop display ordering
- Automatic logical positioning
- Scale-aware layout calculations
- Workspace base alignment
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

## How it works

- `order.json` is the source of the preferred monitor order.
- Hyprland receives a layout with `0x0` for the first monitor and `auto-right` for each following monitor.
- Logical widths account for each monitor's scale and rotation.
- A managed block in `monitors.lua` makes reloads safe.
- `Service.qml` restores the saved state during startup.

## Uninstall / rollback

If the managed monitor block should be removed before uninstalling, run:

```bash
scripts/reorder-displays --remove-config-block
```

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
luac -p "$HOME/.config/hypr/monitors.lua"
git diff --check
omarchy plugin validate .
```

If `qmlformat` is installed, format or validate the QML files before committing:

```bash
qmlformat -i Panel.qml Service.qml
```
