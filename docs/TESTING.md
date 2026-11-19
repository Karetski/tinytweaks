# Testing

We can't run the game in CI, so TinyTweaks is verified in layers. Each layer catches what
the one before it can't. A change is done when every layer that applies to it has passed.

| Tier | Command | What it proves | Where |
|---|---|---|---|
| Static | `make lint`, `make static` | Lua 5.1 syntax, no stray globals (luacheck), TOC parity, taint-contract lint, skill frontmatter | `.luacheckrc`, `tools/check.py` |
| Unit | `make test-unit` | `Core` and pure functions behave | `tests/unit/*_spec.lua` |
| Integration | `make test-integration` | Whole features, driven like a player through the simulated client, with the taint contract enforced | `tests/integration/*_spec.lua` |
| Invariants | `make test-invariants` | Performance properties: skipped work, allocation ceilings | `tests/invariants/*_spec.lua` |
| Bench | `make bench` | Time and KB per op on warm paths, compared across commits (never fails the build) | `tests/bench/*.lua` |
| In game | `/ingame-verify` | Agreement with the real client: look, taint.log, SavedVariables | the user's client |

`make check` runs static + unit + integration + invariants, and CI runs the same
(`.github/workflows/ci.yml`, on Lua 5.1 and LuaJIT). After every `.lua` edit, Claude
Code's hook (`scripts/claude-post-edit.sh`) runs the fast tiers and reports failures.

## The simulated client

`tests/support/wow.lua` is a model of the parts of the client the addon touches:
widgets, events, timers, combat, SavedVariables, Edit Mode and the raid container. Each
test gets a fresh world:

```lua
local world = wow.new()            -- optionally with existing saved data, to test migrations
local ns = world:loadAddon()       -- loads the TOC's files in order, isolated env (no os/io/require)
world:selectSystem(frame)          -- player-like helpers: typeInto, moveSlider, dragSystem, switchLayout, setCombat…
world:nextFrame()                  -- runs C_Timer.After(0) callbacks
```

It enforces the taint contract (principle P2). Blizzard frames are guarded proxies, and
a flag records whether Blizzard's code or the addon's is running. A test fails if the
addon:

- writes a field on a Blizzard frame or table;
- calls a Blizzard method that changes Edit Mode or raid layout state, or `SetScript`
  on a Blizzard frame;
- opens the game's settings with `SettingsPanel:Open` or `:OpenToCategory` instead of
  `Settings.OpenToCategory`;
- parents a frame to the Edit Mode settings dialog or `MinimapCluster`;
- moves, scales, resizes, shows or hides a protected frame in combat.

**It is a model, not the game.** Every assumption about Blizzard behavior is listed in
its header. When the game disagrees, fix the emulator first (with source from
`/blizzard-source`), then the addon (P11). New Blizzard surface the addon starts
touching is modeled in the same change, with state-changing methods added to the guard
lists.

## Conventions

- Names are scenarios: `test("given_<setup>_when_<action>_then_<outcome>", fn)`. Bodies are
  sectioned with `-- Given`, `-- When`, `-- Then`. See the `behavioral-testing` skill.
- Drive behavior through what a player does and sees: positions, scales, panel text,
  saved data. Reach into internals only when that is strictly the stronger test.
- One spec file per feature. Every behavior change carries a scenario that fails without
  it. Every storage change carries a migration test that starts from the old saved data.
- Known gaps are `skip(name, reason)`, never deleted tests.
- A fix's regression test must fail without the fix. To prove it, load the pre-fix revision of
  the file in place of the working copy:
  `world:loadAddon({ replace = { ["EditModeFineTune.lua"] = "<path to the old copy>" } })`
  (for example from `git show HEAD:EditModeFineTune.lua`), run the test, and confirm that it fails.
- Invariant ceilings are measured, with their headroom explained in the test. A failing
  invariant means the change is wrong; raise a ceiling only with a measurement.
- Bench numbers include the emulator's overhead and run on LuaJIT, so trust trends and
  allocation, not absolute client time (see [PERFORMANCE.md](PERFORMANCE.md)).

## Running

```sh
luajit tests/run.lua                    # unit + integration + invariants
luajit tests/run.lua integration -f grid
luajit tests/run.lua tests/integration/position_spec.lua
luajit tests/run.lua bench
```

## In game

The emulator is a model; a change is done only after it runs in the client (`/ingame-verify`).
That step is click-and-look for the person playing; recording is automatic:

- `make link` installs the addon and the dev-only recorder `dev/!TinyTweaksDev` (never
  packaged). The recorder loads before TinyTweaks, turns on `taintLog`, and saves Lua errors
  and warnings, blocked actions, slider moves and snapshots of the Edit Mode frames and raid
  groups to `TinyTweaksDevLog` (written on `/reload` or logout).
- `make ingame-wait` blocks until the game logs out (it ignores `/reload`), then prints the
  report; `make ingame-report` prints it for the last session. The report lists TinyTweaks'
  errors and taint.log entries, checks every saved typed value and offset against the
  frame's state at logout, shows the raid grid as placed on screen, and replays the session's
  trail.
- The report's checks live in `tools/ingame_report.lua` and are unit-tested in
  `tests/unit/ingame_report_spec.lua`. The recorder itself only runs in the client; the taint
  lint and luacheck cover it.

Taint logging costs a little; when not developing, disable TinyTweaks Dev in the AddOns list
and run `/console taintLog 0` once.
