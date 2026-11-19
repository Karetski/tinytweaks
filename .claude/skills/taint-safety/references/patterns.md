# Safe patterns

Recipes that hold the taint contract. Each is used in the codebase today; search for the
named function to see the live version.

## Re-apply a value after Blizzard applies its own

Use when Blizzard's handler for a setting is a single widget call (`SetScale`,
`SetAlpha`) and you want a different value.

1. Post-hook the per-setting handler on the system frame:
   `hooksecurefunc(frame, "UpdateSystemSettingSize", fn)`.
2. In the hook, check the same conditions Blizzard's handler checks (initialized, setting
   present, mode flags), then make the same widget call with your value. On system frames,
   `SetScale`, `SetPoint` and `ClearAllPoints` are Blizzard Lua overrides
   (`SetScaleOverride` re-anchors through `SetPointOverride`, which writes Edit Mode state).
   Call the originals `SetScaleBase`, `SetPointBase` and `ClearAllPointsBase`, and repeat
   whatever the override does that matters (`SetScaleKeepingPosition` in
   `EditModeFineTune.lua` repeats the offset compensation). If the override does something
   addon code can't repeat, such as re-running `ManageFramePositions` for a managed frame in
   its default position, don't support that case.
3. Store, next to the value, the Blizzard raw value it was made against; skip the
   override when the raw value differs (validated overlay, below).

Never call the handler yourself to "refresh". Reproduce its widget call instead.
Live example: `ApplyValue` in `EditModeFineTune.lua`.

## Follow every system frame, now and later

```lua
ns:ForEachSystemFrame(Hook) -- registered frames now, and each one Blizzard registers later
```

`Hook` must be idempotent (a local `hooked[frame] = true` set) because a frame can be
registered again. Call it inside `ns:WhenLoaded("Blizzard_EditMode", ...)`.

## Move a frame relative to its Edit Mode pin

Post-hook `ApplySystemAnchor`, read `frame.systemInfo.anchorInfo`, and call the
*original* widget `SetPoint`: `local setPoint = frame.SetPointBase or frame.SetPoint`.
Blizzard overrides `SetPoint` on system frames; calling the override runs Blizzard code
from addon code. Anchor offsets in `anchorInfo` are at scale 1.0; divide by
`frame:GetScale()`. Live example: `ApplyOffset` in `EditModePosition.lua`.

## Defer protected work until combat ends

```lua
if InCombatLockdown() and frame:IsProtected() then
	ns:RunAfterCombat(Apply, frame) -- runs Apply(frame) once when combat ends
	return
end
```

`ns:RunAfterCombat` runs each function/argument pair once, however often it was queued, in
the order first queued, so repeated triggers in combat collapse into one apply. Queue the
function that settles the frame's whole state, not just one value. Tell the player when an
input can't apply now (`UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, ...)`).

## Side panel for the Edit Mode settings dialog

```lua
panel = CreateFrame("Frame", nil, UIParent)          -- not the dialog
panel:SetFrameStrata(dialog:GetFrameStrata())
panel:SetPoint("TOP", dialog, "BOTTOM", 0, 2)        -- anchored, not parented
dialog:HookScript("OnShow", Update)
dialog:HookScript("OnHide", function() panel:Hide() end)
hooksecurefunc(dialog, "UpdateDialog", Update)
```

`Update` reads `dialog.attachedToSystem` and never writes to the dialog.

## Settings page and minimap button

```lua
page = CreateFrame("Frame")                          -- no parent: the panel reparents it
page:Hide()                                          -- so each display runs OnShow
page:SetScript("OnShow", UpdatePanel)
category = Settings.RegisterCanvasLayoutCategory(page, "TinyTweaks")
Settings.RegisterAddOnCategory(category)
Settings.OpenToCategory(category:GetID())           -- the only way to open it

button = CreateFrame("Button", nil, Minimap)         -- Minimap, never MinimapCluster
```

`Settings.OpenToCategory` is a C call that opens the panel as secure code.
`SettingsPanel:Open` and `:OpenToCategory` run `ShowUIPanel` and the whole panel as addon
code; the emulator and the lint flag them. Don't set `OnRefresh`, `OnCommit` or `OnDefault`
on the page (the panel calls them), and don't add `StaticPopupDialogs` entries (a Blizzard
table). `MinimapCluster` is an Edit Mode system and a resize-layout frame that walks its
direct children. Live example: `Options.lua`.

## Decorate a Blizzard pooled widget

Keep the addon widget in a weak-keyed local table, not as a field on the pooled frame:

```lua
local inputs = setmetatable({}, { __mode = "k" }) -- Blizzard slider frame -> our box
```

Pooled frames get reused for other settings; re-check eligibility every time the dialog
updates and hide the decoration when it doesn't apply. To hide Blizzard's own label,
use `SetAlpha(0)`, not `Hide()`: Blizzard re-shows it on every value change.

## Validated overlay

Store `{ value = ours, raw = blizzards }` (or `{ x, y, pin = copy of anchorInfo }`).
Apply only while Blizzard's current value equals the stored one; when Blizzard's
changes, drop or ignore the overlay. Disabling the addon then leaves Blizzard's own
value in effect. This is principle P1 in `docs/ARCHITECTURE.md`.

## Re-flow a Blizzard container

When Blizzard's layout must be reproduced (the raid container), port the layout function
as a read-only copy that positions frames with widget calls, run it right after
Blizzard's own pass (post-hook the last function of the pass, `LayoutFrames`), under
`pcall`, with a re-entrancy flag. Never write the container's fields. Live example:
`ReflowContainer` in `RaidGroupGrid.lua`.
