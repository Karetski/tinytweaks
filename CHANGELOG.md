# Changelog

Player-facing changes, newest first. Add an entry under *Unreleased* with every change a
player can notice; development tooling and refactors don't belong here.

## Unreleased

- Typed sizes no longer run Blizzard's Edit Mode code, which could taint Edit Mode. Frames keep
  their position on screen when you type a size.
- Frames that Blizzard lines up automatically get a size box only after you move them out of
  their default position, and the Party frame gets none while the game forces its scale.
- Raid group grid: after stepping Columns from 8 back to 4 with *Down*, switching to *Across*
  keeps 4 columns instead of jumping to 7.

## 0.1.0

- Finer Edit Mode values: type exact size, scale or opacity values into supported Edit
  Mode sliders, saved per layout.
- Position offset: move a frame by an exact X/Y offset from where Edit Mode pinned it,
  saved per layout.
- Raid group grid: arrange raid groups 1–8 in a grid with a chosen column count, fill
  order, starting corner and spacing.
