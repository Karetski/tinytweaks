---
name: taint-safety
description: The taint contract for TinyTweaks, which runs inside Blizzard's secure UI. Covers which Blizzard interactions are safe (post-hooks, reading state, re-doing a widget call) and which taint (writing Blizzard tables or frame fields, calling Blizzard Edit Mode functions, parenting into Blizzard layout frames, touching protected frames in combat). Use when writing or reviewing any code that hooks, reads, moves, scales or parents relative to a Blizzard frame, when adding a Blizzard method to the emulator's guard lists, or when diagnosing "action blocked", "execution tainted by TinyTweaks" or secret-value errors.
paths:
  - "*.lua"
  - "tests/support/**"
---

# taint safety

WoW runs Blizzard UI code as *secure* and addon code as *tainted*. Taint spreads: any
value, table field or function call that addon code touches becomes tainted, and a
secure Blizzard path that later reads it runs tainted. That path is then blocked from
protected actions and, on this client, fails on *secret values* ("execution tainted by
TinyTweaks"). The failure shows up far from the cause, often only after `/reload`, in
combat, or in another addon's frame. So the rules are absolute and mechanical.

Sources for the model: warcraft.wiki.gg *Secure Execution and Tainting*, *API
hooksecurefunc*, and the Patch 12.0.0 API notes on secret values.

## The contract

| Allowed | Forbidden |
|---|---|
| `hooksecurefunc(obj, "Method", fn)` and `frame:HookScript(...)` post-hooks | Replacing a Blizzard function or method, `SetScript` on a Blizzard frame, pre-hooks |
| Reading Blizzard fields and calling Blizzard getters | Writing any field on a Blizzard frame or into a Blizzard table (`settingMap`, `dirtySettings`, `systemInfo`, pools…) |
| Re-doing the *widget* call Blizzard's handler makes. On system frames `SetScale`, `SetPoint` and `ClearAllPoints` are Blizzard Lua overrides: use `SetScaleBase`, `SetPointBase`, `ClearAllPointsBase`, and for scale repeat the override's offset compensation. `SetAlpha` is a plain widget call | Calling Blizzard functions that change Edit Mode state (`OnSystemPositionChange`, `UpdateSystemSetting*`, `OnSettingValueChanged`, `ApplySystemAnchor`, `UpdateSystems`, `SetSettingValue`, `LayoutFrames`…) |
| Addon frames parented to `UIParent`, anchored to a Blizzard frame | Parenting an addon frame to a Blizzard layout frame (the settings dialog, raid container, `MinimapCluster`) whose layout code iterates children |
| Addon state in local tables keyed by the Blizzard frame (`applied[frame]`, weak-keyed `inputs[slider]`) | Storing addon state as fields on Blizzard frames, including pooled ones |
| Deferring protected-frame work to `PLAYER_REGEN_ENABLED` | Moving, scaling or showing a protected frame while `InCombatLockdown()` |
| `local` everything; the only global is `TinyTweaksDB` | Any other global (it can collide with, or be read by, secure code) |

When in doubt, the question is: *will Blizzard's secure code ever read something this
line wrote, or run because this line called it?* If yes, it is forbidden.

## How it is enforced

- **Emulator** (`tests/support/wow.lua`): Blizzard-owned frames are guarded. An addon
  write to one raises `taint: addon wrote <field>`, a call to a guarded Blizzard method
  from addon code raises `taint: addon called <method>`. Every integration test therefore
  checks the contract. When a new Blizzard method or table enters the addon's reach, add
  it to the emulator's guard lists in the same change.
- **Lint** (`python3 tools/check.py --only taint`): flags the same patterns statically.
  A line that is genuinely safe takes `-- taint-ok: <reason>`; the reason must name why
  secure code never reads the result. Prefer refining the rule over adding escapes.
- **In game**: `/console taintLog 1`, reproduce, then read
  `_forever_/Logs/taint.log` (see the `ingame-verify` skill). Turn it off afterwards.

## Patterns

Load only what the work needs:

| Need | Reference |
|---|---|
| Safe recipes: apply a value after Blizzard, follow every system frame, defer for combat, an Edit Mode side panel, a settings page and minimap button, a validated overlay | `references/patterns.md` |
| Hazards already discovered in this project, with symptoms and root causes | `references/hazards.md` |

## Red flags in a diff

- `frame.someField = ...` where `frame` came from Blizzard (a hook argument,
  `dialog.attachedToSystem`, `EditModeManagerFrame.registeredSystemFrames`, a pool).
- `CreateFrame(..., EditModeSystemSettingsDialog)`, `MinimapCluster` or any Blizzard
  dialog/container as parent.
- `SettingsPanel:Open()` or `SettingsPanel:OpenToCategory()`: they run the whole panel as
  addon code. Open a settings page only with `Settings.OpenToCategory(category:GetID())`.
- A Blizzard method called with `:` that is not a getter (`Get*`, `Is*`, `Has*`,
  `Should*`, `Can*`).
- `:SetScale(`, `:SetPoint(` or `:ClearAllPoints(` on an Edit Mode system frame: those are
  Blizzard's overrides, not widget calls.
- `SetScript` where `HookScript` would do.
- A protected-frame widget call without an `InCombatLockdown()` guard on the path.
- A new global, or a missing `local`.
- "It's only read by our code": check whether Blizzard iterates the table or frame too.

A finding here is a blocker, not a nit. Name the rule, the line and what secure code
will read.

## Record new hazards

When a taint bug is found, fix the root cause, add a test that reproduces it in the
emulator (extend the guard lists if needed), and add an entry to
`references/hazards.md`: symptom, root cause, the rule it violates, the fix. Each entry
must stand alone for a reader who has never seen the bug.
