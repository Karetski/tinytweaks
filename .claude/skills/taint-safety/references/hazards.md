# Known hazards

Taint and Blizzard-interaction problems found in this project. Each entry: symptom, root
cause, the rule it violates, the fix in place. Add one entry per newly discovered hazard.

## Calling Blizzard's setting code from the addon taints the settings dialog

- **Symptom:** after using a TinyTweaks control, unit frame code fails with secret-value
  errors ("execution tainted by TinyTweaks") until `/reload`; native settings such as raid
  frame size stop applying.
- **Root cause:** calling `UpdateSystemSetting*`, `OnSystemPositionChange` or similar from
  addon code runs the whole settings dialog path tainted, and the dialog then hands
  tainted values to secure unit frame code.
- **Rule:** never call Blizzard functions that change Edit Mode state.
- **Fix:** repeat only the widget call the handler makes (`SetScale`, `SetAlpha`,
  `SetPointBase`). Fine-tune is limited to sliders whose handler is exactly one such call.

## Addon children of the settings dialog taint its layout

- **Symptom:** native Edit Mode settings break after the TinyTweaks panel is shown.
- **Root cause:** the settings dialog is a resize-layout frame. Its layout code iterates
  children and reads their fields, so an addon child taints it.
- **Rule:** never parent into a Blizzard layout frame.
- **Fix:** panels are parented to `UIParent`, anchored to the dialog, and shown or hidden
  from `OnShow`/`OnHide` hooks.

## Blizzard's `SetScale`, `SetPoint` and `ClearAllPoints` overrides on system frames

- **Symptom:** Edit Mode taint after typing a size or moving a frame from the addon, possibly in
  unrelated frames. Blizzard code running as TinyTweaks records snaps and marks Edit Mode's
  anchors dirty. For a managed frame in its default position it also re-runs
  `ManageFramePositions`.
- **Root cause:** every Edit Mode system frame replaces `SetScale`, `SetPoint` and
  `ClearAllPoints` with Blizzard Lua (`SetScaleOverride`, `SetPointOverride`,
  `ClearAllPointsOverride`) and keeps the widget methods as `SetScaleBase`, `SetPointBase` and
  `ClearAllPointsBase`. Calling `frame:SetScale(…)` on a system frame therefore runs Blizzard code
  from addon code. The scale override also moves the frame's points to keep it in place, so a
  plain widget `SetScale` without that compensation makes the frame drift.
- **Rule:** on a system frame, call only the `*Base` methods, and repeat whatever part of the
  override matters. If the override does something addon code can't repeat, such as re-running
  a managed container's layout, don't support that case.
- **Fix in place:** `SetScaleKeepingPosition` in `EditModeFineTune.lua` calls `SetScaleBase`,
  then scales each point's offsets by old/new through `SetPointBase`. It skips managed frames in
  their default position. `ApplyOffset` in `EditModePosition.lua` moves frames with
  `SetPointBase`. The emulator flags an addon call to any of the three overrides.

## Writing Blizzard settings tables

- **Symptom:** tainted saves, or settings that revert.
- **Root cause:** `settingMap` and `dirtySettings` are read by secure save code.
- **Rule:** never write into Blizzard tables.
- **Fix:** TinyTweaks keeps its own values in `TinyTweaksDB`, per layout.

## Hooking a high-frequency layout function

- **Symptom:** dozens of grid re-applications per slider step; visible lag in Edit Mode.
- **Root cause:** `FlowContainer_DoLayout` runs many times per Blizzard re-flow.
- **Rule:** hook the narrowest, least frequent function that guarantees correctness (see
  `docs/PERFORMANCE.md`).
- **Fix:** hook `CompactRaidFrameContainer:LayoutFrames`, which ends every re-flow once.

## Secret anchors (open risk, not yet observed)

- **Symptom to watch for:** Lua errors from `EditModePosition` arithmetic or comparisons
  ("attempt to compare/perform arithmetic on a secret value"), most likely in combat or
  on frames that show combat information.
- **Root cause (per the 12.0 API notes, unverified on the Forever client):** when a widget
  receives a secret value it becomes secret, and secrecy propagates *down* its anchor
  chain. `GetPoint`, `GetWidth` and similar then return secrets to tainted code, and
  tainted code may not compare or do arithmetic on them. Concatenation, `format` and
  passing them back into widget APIs are allowed.
- **Rule:** before doing math on geometry read from a frame that may be secret, check
  `frame.IsAnchoringSecret and frame:IsAnchoringSecret()` or
  `issecretvalue and issecretvalue(v)`, and skip the work when it's secret.
- **Fix in place:** none yet. `ApplyOffset` compares the `GetPoint` point names and uses
  `anchorInfo` offsets (Blizzard's stored values, not widget geometry), which limits the
  exposure. Confirm in game before adding guards.

## Protected raid frames in combat

- **Symptom:** "action blocked" or groups snapping back during combat roster changes.
- **Root cause:** raid frames are protected; widget calls on them are refused in combat.
- **Rule:** defer protected work to `PLAYER_REGEN_ENABLED`.
- **Fix:** during combat Blizzard's layout stands; the grid re-applies when combat ends.

## Opening the settings panel in combat

- **Symptom:** clicking the minimap button in combat does nothing, and each click raises
  `ADDON_ACTION_BLOCKED` naming TinyTweaks and `OpenSettingsPanel()`.
- **Root cause:** `Settings.OpenToCategory` calls `C_SettingsUtil.OpenSettingsPanel`, which
  is restricted (`HasRestrictions`); the client refuses it from addon code in combat.
- **Rule:** never call a restricted API from addon code while `InCombatLockdown()`.
- **Fix:** in combat the button shows `ERR_NOT_IN_COMBAT` instead; the emulator flags the
  call in combat as a blocked action.
