# Architecture

TinyTweaks makes small changes to World of Warcraft's native UI (Interface 16001, the
"Forever" client). This document is the project's design rubric: the principles every
change is reviewed against, the shape of the code, the storage model, and the record of
decisions that are not obvious from the code. Review skills (`addon-review`,
`principle-review`) read it as the source of truth.

Companion documents: [TESTING.md](TESTING.md) (how changes are verified) and
[PERFORMANCE.md](PERFORMANCE.md) (budgets and measurement). The taint rules live in the
`taint-safety` skill (`.claude/skills/taint-safety/`).

## The one invariant

**Blizzard's UI stays authoritative and untainted.** TinyTweaks only *observes* Blizzard
state and *adds* to what the player sees. If TinyTweaks is disabled, deleted, or throws an
error, the native UI works exactly as it would without it. Every principle below is a
consequence of this one.

## Principles

Each principle names its inspiration, what it means here, and what it forbids. Chris
Lattner's work (LLVM, Clang, Swift, MLIR, Mojo) supplies most of the spine; sources are
listed at the end. A principle is a hard constraint: a change that breaks one is revised,
or the principle is changed here first, with the reasoning recorded in the decision log.

### P1. Overlay, don't own

*Inspiration: single source of truth; Swift's value semantics (state you hold is a value,
not a shared reference you mutate).*

Blizzard's Edit Mode layout is the source of truth for everything it stores. TinyTweaks
stores **deltas** next to it, and each delta records the Blizzard value it was made
against: a typed slider value stores the raw slider step (`raw`); a position offset stores
the pin (`pin`). The delta applies only while that Blizzard value is unchanged. When the
player moves the slider, re-pins the frame, reverts or resets the layout, the delta
invalidates itself instead of fighting Blizzard.

- **Forbids:** writing TinyTweaks values into Blizzard's layout, settings tables or saved
  layouts; a delta without the Blizzard value it was made against; a delta that survives
  a Blizzard change it was not made for.
- **Red flag:** a stored value that is applied unconditionally on every hook.

### P2. Safe by default: make the right thing easy and the wrong thing hard

*Inspiration: Lattner's Swift Concurrency Manifesto asks for a "safe by default" model
in which "there should be a structured 'right' way to achieve most tasks".*

Taint is the failure mode that breaks other people's UI (secret-value errors, blocked
actions) and it surfaces far from its cause. So the safe operations are the only
convenient ones, and the unsafe ones are refused mechanically:

- Post-hooks only (`hooksecurefunc`, `HookScript`). Never replace or pre-hook a Blizzard
  function or script.
- Read Blizzard state; never write fields into Blizzard frames or tables.
- Never call a Blizzard function that changes Edit Mode state. Re-do only the *widget*
  call Blizzard's handler makes, through the original widget methods: `SetAlpha`, and on
  system frames `SetScaleBase`, `SetPointBase` and `ClearAllPointsBase`. Blizzard replaces
  `SetScale`, `SetPoint` and `ClearAllPoints` on system frames with Lua overrides.
- TinyTweaks frames are parented to `UIParent` and anchored to Blizzard frames, never
  parented into Blizzard layout frames.
- Protected frames are never touched in combat; work is deferred to
  `PLAYER_REGEN_ENABLED`.

The emulator in `tests/support/` raises on any write to a Blizzard-owned table and any
call to a guarded Blizzard method, and `tools/check.py` lints for the same patterns. A
rule the build cannot enforce is a wish; when a new hazard is discovered, it becomes a
check, not a comment.

### P3. Library-based design

*Inspiration: LLVM "was designed as a set of reusable libraries with well-defined
interfaces" (Lattner, AOSA). Tools are assembled from the libraries they need.*

`Core.lua` is a small library (events, Blizzard-addon load gating, per-layout storage,
work deferred until combat ends, visiting every Edit Mode system frame, output). Each feature is one module file that depends only on `Core`. Modules never
reference each other: the only shared state is the `ns` namespace that `Core` defines.
This keeps every feature independently removable and testable, and is why disabling
a feature can never break another.

- **Forbids:** module → module references; feature logic in `Core`; a helper copied into
  a third module (the third copy moves into `Core`, see the backlog).
- **Red flag:** `ns.<OtherModule>` used inside a module.

### P4. Read, compute, apply: separate the levels

*Inspiration: MLIR's progressive lowering, "in small steps along multiple abstraction
levels", with each transformation at the level that understands it; and Gary Bernhardt's
"functional core, imperative shell".*

Every feature runs the same three steps, and they stay distinct in the code:

1. **Read**: turn Blizzard state into plain Lua values (the frame's pin, the slider's raw
   value, group sizes, the active layout key).
2. **Compute**: pure functions from those values and the stored deltas to a plan (grid
   cells, final offset, clamped value, a pin label). No WoW API calls.
3. **Apply**: widget calls that realize the plan, guarded for combat and initialization.

Pure compute functions are the unit-test surface and the place where most logic should
live. A function that mixes all three is hard to test and hard to reason about under
taint.

- **Red flag:** a compute function that calls `CreateFrame`, `GetPoint`, `InCombatLockdown`
  or reads a Blizzard global.

### P5. Progressive disclosure of complexity

*Inspiration: Lattner on Swift: "the complexity inherent in the language needs to be
progressively disclosed". It should be easy to start and still powerful, with complexity
revealed only when you need it.*

For players: a feature appears only where and when it applies (the Group Layout panel
only for raid frames, the input box only on sliders TinyTweaks can apply safely). Defaults
are Blizzard's own behavior; every TinyTweaks setting starts off or at zero. Explanations
live in tooltips and in short status notes ("Only applies when Groups is set to
Separate."), not in walls of text. When something can't be used, say why
(`GetBlockedReason` is the model: a short reason plus an explanation in the tooltip).

For developers: each module opens with a doc block that explains the model (what is
stored, when it applies, the taint notes) before any code.

### P6. Pay only for what you use

*Inspiration: LLVM's libraries support advanced uses "without punishing clients of the
libraries that just want to do simple things" (Lattner, AOSA); the zero-overhead
principle of C++ and Mojo.*

A feature the player has not enabled costs a branch per hook, nothing more. Hooks are on
the narrowest, least frequent Blizzard function that guarantees correctness. UI is built
once and reused. Budgets and measurement: [PERFORMANCE.md](PERFORMANCE.md).

### P7. Probe capabilities, never assume versions

*Inspiration: LLVM's target descriptions (code asks what the target can do rather than
which target it is).*

The client's API moves under us. Look up enums, methods and globals and treat absence as
"feature unavailable": `Enum.X and Enum.X.Y`, `type(frame[method]) == "function"`,
`C_AddOns and C_AddOns.IsAddOnLoaded`. A missing capability disables the affected part
quietly; it never raises.

- **Forbids:** branching on build numbers or `## Interface` values; indexing a Blizzard
  enum or method without a nil guard where the client might not have it.

### P8. Contain failure at the boundary

*Inspiration: Erlang's "let it crash" isolation, applied to a guest inside someone else's
process.*

TinyTweaks code runs inside Blizzard's call stacks. Non-trivial work triggered from a
Blizzard hook runs under `pcall` and reports through `geterrorhandler()`, so a TinyTweaks
bug shows an error instead of aborting Blizzard's flow halfway (the raid reflow is the
model). Re-entrancy is guarded explicitly (`reflowing`).

### P9. Explicit, versioned storage

*Inspiration: Lattner: "We cannot build a conceptually beautiful new world without also
building a pathway to get existing apps into it." Once data is written, its format is a
contract with every player who has it.*

SavedVariables outlive the code that wrote them. The schema is documented below. Every
format change ships with a migration that is idempotent (safe to run twice), pure (a
function from old table to new table) and covered by a test that starts a world from the
old saved data. Migrations run once at load, over every layout, in the module's `Init`;
reads never migrate. A version number is added the first time a migration can't be made
idempotent (decision D8).

### P10. Small changes, each with a test

*Inspiration: the LLVM Developer Policy of the project Lattner founded: "each change
should be kept as small as possible", test cases for every fix and feature, and "'revert
to green' as opposed to 'fixing forward'".*

A commit does one thing and carries the test that proves it. A behavior change and a
refactor never share a commit. When a change breaks the native UI in-game, revert first,
diagnose second. See the `commit-discipline` skill in agentkit for commit shape.

### P11. The test infrastructure is part of the product

*Inspiration: LLVM's textual IR enables "highly focused regression tests that can load
LLVM IR from disk" (Lattner, AOSA), run by `lit` and `FileCheck`. A fast in-tree harness
is what makes a compiler safe to change.*

We cannot run the game in CI, so the emulator in `tests/support/` is how changes are
verified between in-game sessions. It is maintained with the same care as the addon:
every Blizzard behavior it models is written down as an assumption, and when in-game
behavior disagrees with it, the emulator is fixed first, then the addon. A passing suite
proves agreement with the model, not with the game; the in-game check (`ingame-verify`
skill) closes that gap.

### P12. Quality of implementation shows in the details

*Inspiration: Lattner on Clang: a compiler should "give you a hint that explains what is
wrong so you can fix the problem". The error message is part of the product.*

User-facing text is short, plain and specific, written in the same voice as Blizzard's
UI. Numbers display without trailing zeros. Disabled controls look disabled and say why.
Values typed by the player are normalized (comma decimals, `%`, whitespace) and clamped,
never rejected silently.

## Code shape

```
TinyTweaks.toc          load order: Core first, then one file per feature
Core.lua                the library: ns, events, WhenLoaded, layout storage, RunAfterCombat, ForEachSystemFrame, Print, ShowTooltip
EditModeFineTune.lua    feature: typed values for safe Edit Mode sliders
EditModePosition.lua    feature: X/Y offsets from a frame's Edit Mode pin
RaidGroupGrid.lua       feature: raid groups arranged in a grid
Options.lua             the TinyTweaks settings page (Options → AddOns) and the minimap button
tests/                  runner, emulator (support/), unit, integration, invariants, bench
tools/check.py          TOC parity, taint-contract lint, skill validation
docs/                   this rubric, testing, performance
```

### Module anatomy

Every feature module has the same order, so a reader always knows where to look:

1. **Doc block**: what the feature does, the model (what is stored, when it applies, when
   it invalidates), **Taint notes** (which Blizzard code it touches and why that is safe).
2. **Registration**: `local M = {}; table.insert(ns.modules, M)`.
3. **Constants and storage access** (`Get…(create)` accessors over `ns:GetLayoutDB`).
4. **Compute**: pure helpers (P4).
5. **Apply**: widget calls, combat guards, deferral.
6. **Blizzard hooks**: the post-hook bodies.
7. **Panel**: UI built once, refreshed by an `UpdatePanel` that reads state and never
   stores it.
8. **Init**: `M:Init()` runs at `ADDON_LOADED`; it wires hooks inside
   `ns:WhenLoaded("Blizzard_…")`, and migrates old saved data.

### Lifecycle

```
ADDON_LOADED(TinyTweaks)  → TinyTweaksDB initialized → each module:Init() in TOC order
  WhenLoaded(Blizzard_EditMode / Blizzard_CompactRaidFrames)
    → hook already-registered system frames, and RegisterSystemFrame for later ones
    → create panels (parented to UIParent), hook the settings dialog
Blizzard runs its own code   → our post-hook reads state → compute → apply
In combat, protected frame   → mark pending → PLAYER_REGEN_ENABLED → apply
Layout switch / revert       → UpdateSystems post-hook → re-validate every delta
```

### Storage schema

```lua
TinyTweaksDB = {
	layouts = {
		-- "<layoutType>:<layoutName>", plus ":<character>-<realm>" for character layouts
		[layoutKey] = {
			overrides = { -- EditModeFineTune
				["<system>:<systemIndex>"] = { [setting] = { value = number, raw = number } },
			},
			positions = { -- EditModePosition
				["<system>:<systemIndex>"] = {
					x = number, y = number,
					pin = { point, relativeTo, relativePoint, offsetX, offsetY }, -- Blizzard anchorInfo copy
					label = string, -- what the frame snapped to, for display
				},
			},
			groupGrid = { -- RaidGroupGrid
				enabled = boolean, columns = 1..8, order = "across"|"down",
				corner = "TOPLEFT"|"TOPRIGHT"|"BOTTOMLEFT"|"BOTTOMRIGHT",
				hSpacing = 0..100, vSpacing = 0..100,
			},
		},
	},
	minimap = { -- Options; account-wide, absent while at the defaults (shown, at 225 degrees)
		hide = true?, angle = 0..360, -- degrees counterclockwise from the right of the minimap
	},
}
```

Keys a module owns are listed under it; a module never reads another module's keys.

## Dependency direction

```
Blizzard UI (read-only, post-hooked)
        ↑ reads / hooks
Core.lua  ←  EditModeFineTune.lua
          ←  EditModePosition.lua
          ←  RaidGroupGrid.lua
          ←  Options.lua
```

Arrows point at what a file depends on. Nothing depends on a feature module.

## Conformance backlog

Where the proof-of-concept code departs from the principles above, ranked by value. Each
item is its own commit, done when the area is next touched, with the integration suite
green before and after (the suite characterizes current behavior, so these are safe
refactors).

1. **Pure logic lives in module locals** (`GetCells`, `GetGridSize`, `JoinLabels`,
   `DescribeSnapInfo`, value parsing and clamping). The integration suite covers it
   through behavior, which is the stronger test while the logic stays this small. Expose
   a module's compute layer for unit tests (P4) when its cases outgrow what scenarios
   cover cheaply, for example a new layout algorithm with many edge cases.
2. **`SystemKey` and number parsing are duplicated** across modules. Move each into `Core`
   when a third copy would appear (P3), as `ns:ShowTooltip` was.
3. **`UpdatePanel` runs several times per selection** (it is hooked on `UpdateSettings`,
   `AttachToSystemFrame`, `OnShow`, `UpdateDialog`, `UpdateRaidContainerFlow`,
   `UpdateSystems`). Coalesce to once per frame if measurement shows a cost (P6).

## Decision log

Durable decisions that the code alone does not explain. Add an entry when a decision is
made; change an entry only by superseding it.

- **D1. Settings live inside Edit Mode.** *(Superseded in part by D9.)* Each feature's
  controls appear next to the Edit Mode settings dialog of the frame they affect. There is
  no separate options window. *Why:* progressive disclosure (P5) and storage per Edit Mode
  layout.
- **D2. Panels are parented to `UIParent`, anchored to the dialog.** *Why:* the dialog is
  a resize-layout frame; Blizzard's layout code iterating an addon child taints the
  dialog and breaks native settings such as raid frame size.
- **D3. Never run Blizzard's Edit Mode code from the addon.** Not even "harmless" calls
  like `OnSystemPositionChange`. *Why:* running Blizzard setting code from addon code
  taints the settings dialog, after which unit frame code fails on secret values until
  `/reload`.
- **D4. Fine-tune only sliders whose Blizzard handler is a single `SetScale`/`SetAlpha`.**
  Sliders that feed Blizzard layout math (action bar size, raid frame size, minimap…)
  are excluded. Scale is applied with `SetScaleBase` plus the offset compensation that
  Blizzard's `SetScaleOverride` does, because the override itself is Lua that writes Edit
  Mode state. Managed frames in their default position are excluded, because their scale
  change needs `ManageFramePositions`. *Why:* only these can be re-applied with widget calls
  (D3).
- **D5. Storage is keyed per Edit Mode layout; character layouts include character and
  realm.** *Why:* different characters can have character layouts with the same name.
- **D6. Tests run on a zero-dependency Lua runner and an in-repo client emulator.** Not
  busted with generic WoW stubs. *Why:* no LuaRocks needed locally; the emulator enforces
  the taint contract (P2), which generic stubs cannot; a later move to busted only
  replaces the runner.
- **D7. No formatter is enforced yet.** `.editorconfig` pins tabs; adopting StyLua is a
  one-commit reformat to decide separately. *Why:* a formatter that rewrites every file
  is a gestalt change, not a side effect of tooling setup.
- **D8. No schema version yet.** Every migration so far is idempotent and runs at each
  load, which costs a pass over the saved layouts and needs no bookkeeping. *Why:* a
  version number earns its place only when a migration can't safely run twice; add
  `TinyTweaksDB.version` with that migration.
- **D9. Addon-wide settings live on one page in the game's settings.** Supersedes D1 for
  settings that belong to no Edit Mode frame (the minimap button, debug recording): they go on
  a canvas page registered under Options → AddOns; per-frame settings stay next to the Edit
  Mode dialog. A minimap button, shown by default and hideable from the page, opens it, so
  players can find the page without knowing the menu path. The page is opened only with
  `Settings.OpenToCategory(category:GetID())`, never with `SettingsPanel` methods, and the
  button is a plain addon button parented to `Minimap`, without libraries. *Why:* the C call
  opens the panel as secure code, while `SettingsPanel:Open` runs `ShowUIPanel` and the panel
  tainted; a hand-made button keeps `TinyTweaksDB` the only global and avoids vendoring
  LibStub, LibDataBroker and LibDBIcon for one button. Dragging the button uses an `OnUpdate`
  (T3): following the cursor needs a per-frame read, so it isn't throttled. It is set on drag
  start and cleared on drop or hide, and moves the button only when the cursor's angle changes;
  `tests/invariants/budget_spec.lua` pins both.

## Sources

- Chris Lattner, "LLVM", *The Architecture of Open Source Applications* (library-based
  design, focused regression tests, not punishing simple clients) —
  <https://aosabook.org/en/v1/llvm.html>
- Chris Lattner, Swift Concurrency Manifesto (safe by default, a structured right way, a
  pathway for existing code) — <https://gist.github.com/lattner/31ed37682ef1576b16bca1432ea9f782>
- Chris Lattner, ATP 205 interview (progressive disclosure of complexity) —
  <https://atp.fm/205-chris-lattner-interview-transcript>
- LLVM Developer Policy (small changes, test cases, revert to green; a community policy,
  not Lattner's own words) — <https://llvm.org/docs/DeveloperPolicy.html>
- Lattner et al., "MLIR: Scaling Compiler Infrastructure for Domain Specific Computation"
  (progressive lowering) — <https://arxiv.org/abs/2002.11054>
- Chris Lattner, "Amazing feats of Clang error recovery" (diagnostics) —
  <https://blog.llvm.org/2010/04/amazing-feats-of-clang-error-recovery.html>
- LLVM Testing Guide (`lit`, `FileCheck`) — <https://llvm.org/docs/TestingGuide.html>
- Gary Bernhardt, "Boundaries" (2012) (functional core, imperative shell)
- Taint model: <https://warcraft.wiki.gg/wiki/Secure_Execution_and_Tainting>,
  <https://warcraft.wiki.gg/wiki/API_hooksecurefunc>

Not sourced as Lattner's own words, so not quoted as such here: "pay only for what you
use" (Stroustrup's zero-overhead principle) and "make the right thing easy".
