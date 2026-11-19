# TinyTweaks

A World of Warcraft addon (Lua 5.1, client "WoW Forever", `## Interface: 16001`) that
makes small changes to the native UI through Edit Mode: typed values for some sliders,
X/Y offsets from a frame's pin, and a grid layout for raid groups. Player-facing behavior
is described in `README.md`.

@.claude/agentkit-conduct.md

## The invariant

**Blizzard's UI stays authoritative and untainted.** TinyTweaks only post-hooks, reads
Blizzard state and repeats widget calls; it never writes Blizzard tables or frame fields,
never calls Blizzard's Edit Mode functions, never parents into Blizzard layout frames,
and never touches protected frames in combat. Without TinyTweaks the UI must work exactly
as Blizzard's. Load the `taint-safety` skill before touching any code that interacts with
a Blizzard frame.

## Map

| Path | What |
|---|---|
| `TinyTweaks.toc` | Load order and metadata. Every addon `.lua` file is listed here. |
| `Core.lua` | Shared library: `ns`, events (`ns:On`), `ns:WhenLoaded`, per-layout storage (`ns:GetLayoutDB`) |
| `EditModeFineTune.lua`, `EditModePosition.lua`, `RaidGroupGrid.lua` | One feature each; they depend only on `Core` |
| `Options.lua` | The settings page (Options → AddOns) and the minimap button |
| `docs/ARCHITECTURE.md` | Principles P1-P12, module anatomy, storage schema, backlog, decision log |
| `docs/TESTING.md` | Test tiers, the client emulator, conventions |
| `docs/PERFORMANCE.md` | Frequency tiers, budgets, measuring |
| `tests/` | Runner, emulator (`support/wow.lua`), unit, integration, invariants, bench |
| `dev/!TinyTweaksDev/` | Dev-only recorder addon for in-game sessions (errors, blocked actions, frame snapshots); never shipped |
| `tools/ingame.sh`, `tools/ingame_report.lua` | Wait for logout and report on an in-game session |
| `tools/check.py` | TOC parity, taint-contract lint, skill validation |
| `CHANGELOG.md` | Player-facing changes; add to *Unreleased* with every user-visible change |

## Commands

```sh
make check              # the full gate: lint, tools/check.py, unit + integration + invariants
make test               # tests only;  make test-unit / make test-integration
luajit tests/run.lua -f <name>   # run tests whose name contains <name>
make bench              # timings and KB allocated per op for warm paths
make link               # symlink this repo and the dev recorder into the game's AddOns folder
make ingame-wait        # wait for the game to log out, then report on the session
make ingame-report      # report on the last in-game session
make dist               # build dist/TinyTweaks-<version>.zip
```

`make check` must pass before every commit. A hook re-runs the fast checks after each
edit of a `.lua` file and reports failures back.

## How work is done here

1. **Understand Blizzard first.** Before hooking or repeating anything Blizzard does, read
   its source with `/blizzard-source <question>`. Never guess at Edit Mode internals.
2. **Tests before code.** Behavior is pinned by scenarios against the emulator
   (`given_<setup>_when_<action>_then_<outcome>`). New Blizzard behavior is modeled in
   the emulator first, with state-changing methods on its taint guard lists.
3. **Follow the module anatomy** in `docs/ARCHITECTURE.md`. Read → compute (pure) → apply.
4. **Verify in game.** The emulator is a model. A change is done only after
   `/ingame-verify`, or after saying plainly that it was verified against the emulator only.
   The user only clicks and looks; errors, taint and frame state are recorded and read from
   disk.
5. **Small commits.** One concern each, refactors separate from behavior, every commit
   green.

## Skills

Project skills:

| Skill | Use |
|---|---|
| `taint-safety` | The taint contract, safe patterns, known hazards. Any code touching Blizzard frames. |
| `blizzard-source` | Look up how Blizzard's UI code behaves (forked, returns a cited answer). |
| `add-feature` | End-to-end procedure for a new or changed feature. |
| `ingame-verify` | Manual test script for the user, then read taint.log and SavedVariables. |
| `addon-review` | Review a change against this project's rubric; ship / revise / reject (forked). |
| `perf-audit` | Frequency-tier audit of hooks and handlers (forked). |
| `release` | Version, changelog, tag and zip (user-invoked only). |

Vendored from agentkit (`.claude/agentkit.lock`; edit upstream and run
`tools/sync-agentkit.sh`, never edit the copies): `behavioral-testing`,
`commit-discipline`, `debugging-methodology`, `function-shape`, `simplify-ruthless`. The
coding conduct imported above comes from the same place.

## Conventions

- Lua 5.1. Tabs. Everything `local`; the only global is `TinyTweaksDB`.
- Each module: `local M = {}; table.insert(ns.modules, M)` and an `M:Init()`.
- Blizzard API: probe before use (`Enum.X and Enum.X.Y`, `type(obj.Method) == "function"`).
- Player-facing text: short, plain, Blizzard's tone; numbers without trailing zeros;
  disabled controls say why.
- Commit subjects: imperative and capitalized ("Add …", "Fix …"), body explains why.
