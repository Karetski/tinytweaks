# TinyTweaks

Small tweaks for the native UI of World of Warcraft Forever (Interface 16001).

## Features

### Finer Edit Mode values
Edit Mode sliders only move in fixed steps. TinyTweaks adds an input box to some size, scale and opacity sliders, so you can type any value and press Enter:

- Size: Bags, Durability, Timer Bars, Vehicle Seat, Archaeology Bar, Group Finder, Loss of Control, Swing Timer, Cast Bar (when not locked to the Player Frame), and Target, Focus, Boss and other unit frames except the Player and Pet frames
- Opacity: unit frames, aura frames, cooldown viewers, personal resource display, Swing Timer

Only sliders that TinyTweaks can apply on its own get a box, so Blizzard's Edit Mode code never runs from the addon. Sliders whose value feeds into Blizzard's layouts (action bar icon size and padding, raid frame width and height, minimap, chat, objective tracker and others) don't get one.

- Frames that Blizzard lines up automatically while they are in their default position (Durability, Vehicle Seat, Archaeology Bar, Swing Timer, Cast Bar, Boss frames) get a size box once you drag them somewhere else. The Party frame gets none while the game forces its scale.
- TinyTweaks stores the typed value per layout. Blizzard's layout keeps the slider's value, so without TinyTweaks the frame uses the slider value.
- Moving the slider again replaces the typed value.

### Position offset
Move a frame away from where it's pinned. A **Position** panel under the selected frame's settings shows:

- **Pinned to**: where Edit Mode placed the frame, such as "Screen center", "Grid line", "Below Player Frame" or "Nothing (placed freely)".
- **X Offset** / **Y Offset**: distance from the pin, as a slider or a typed value. 0 is exactly the pin. Positive X moves right, positive Y moves up.

For example, drag a frame until it snaps to the screen center, then set Y Offset to `-220` to move it straight down while it stays centered.

- Dragging or nudging the frame pins it again and resets the offset to 0.
- Offsets are saved per Edit Mode layout as soon as you change them; Edit Mode's Save button isn't needed. Blizzard's layout keeps only the pin, so without TinyTweaks the frame sits at its pin.
- Frames in their default position have no pin until you drag them once.

### Raid group grid
Arrange the raid groups (1–8) in a grid instead of a single row or column.

- **Columns**: how many columns the grid has; the rows follow from that. With *Down* and 5 to 7
  columns, the first columns hold one group more than the rest (5 columns: 1 3 5 7 8 / 2 4 6)
- **Order**: *Across* fills each row first, *Down* fills each column first
- **Start**: the corner group 1 goes in
- **Spacing**: horizontal and vertical space between groups

| Columns | Order | Start | Result |
|---|---|---|---|
| 4 | Across | Top left | `1 2 3 4` / `5 6 7 8` |
| 2 | Across | Top left | `1 2` / `3 4` / `5 6` / `7 8` |
| 2 | Down | Top left | `1 5` / `2 6` / `3 7` / `4 8` |
| 2 | Across | Bottom right | `8 7` / `6 5` / `4 3` / `2 1` |

Every cell is the size of the largest group. Cells keep their place when a group is empty, so groups never shift. The panel shows a preview of the grid.

Select the raid frames in Edit Mode to open the **Group Layout** panel. It only applies when Groups is set to Separate. Settings are saved per Edit Mode layout.

### Settings and minimap button
TinyTweaks has a page in the game's settings under **Options → AddOns → TinyTweaks**. A minimap button opens it: click it to open the page, drag it to move it around the minimap's edge. To hide the button, uncheck **Show minimap button** on the page.

## Limitations
- Raid frames are protected in combat. If the roster changes during combat, the affected groups use Blizzard's layout until combat ends.
- Typed values on protected frames (such as unit frames) can't change during combat; they apply when combat ends.

## Installation
Copy or symlink this folder into `World of Warcraft/_forever_/Interface/AddOns/TinyTweaks`.

## License
[AGPL-3.0](LICENSE)
