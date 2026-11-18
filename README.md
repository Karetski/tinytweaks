# TinyTweaks

Small tweaks for the native UI of World of Warcraft Forever (Interface 16001).

## Features

### Finer Edit Mode values
Edit Mode sliders only move in fixed steps (action bar icon size, for example, goes in 10% steps). TinyTweaks adds an input box to every size, padding, scale and opacity slider, so you can type any value and press Enter.

- Blizzard's layout keeps the nearest step, and TinyTweaks stores the exact value per layout.
- Moving the slider again replaces the typed value.
- Count sliders (rows, number of icons, icon limits) are left as they are.

### Raid group grid
Lay out the members of each raid group as a grid instead of a single row or column.

- Members per line (1–5)
- Fill order: rows first or columns first
- Horizontal direction: left to right or right to left
- Vertical direction: top to bottom or bottom to top
- Spacing between frames

Select the raid frames in Edit Mode to open the **Group Layout** panel. It only applies when Groups is set to Separate. Settings are saved per Edit Mode layout.

## Limitations
- Raid frames are protected in combat. If the roster changes during combat, the affected groups use Blizzard's layout until combat ends.
- Typed values are fed through Blizzard's Edit Mode code and may cause "Interface action failed" errors in rare cases, such as a layout change during combat.

## Installation
Copy or symlink this folder into `World of Warcraft/_forever_/Interface/AddOns/TinyTweaks`.

## License
[AGPL-3.0](LICENSE)
