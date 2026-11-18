# Agentic development setup — report (2026-11-17)

The addon's own Lua files are unchanged. `make check` passes, including luacheck: 83
tests pass, 1 is skipped and none fail.

## 1. Skills and agent infrastructure

| Piece | Path |
|---|---|
| Project instructions: invariant, map, commands, workflow, skill index. Imports agentkit's coding conduct. | `CLAUDE.md` |
| Project skills (7) | `.claude/skills/` |
| Vendored agentkit skills (5), pinned at `e8216e1` | `.claude/skills/`, `.claude/agentkit.lock`, `.claude/agentkit-conduct.md` |
| Re-sync from agentkit | `tools/sync-agentkit.sh` |
| PostToolUse hook: after each `.lua` edit, runs a syntax check, lint and the fast tests | `scripts/claude-post-edit.sh`, wired in `.claude/settings.json` |
| Permission allowlist for the `make` / test / check commands | `.claude/settings.json` |

**Project skills**

- `taint-safety`: the contract, safe patterns and a hazards ledger. It loads automatically when `*.lua` files are touched.
- `blizzard-source` (forked): answers a question from Blizzard's source. It reads the exported client source first, then the `forever` branch of Gethe/wow-ui-source.
- `add-feature`: an end-to-end procedure. Design, research, model the behavior in the emulator, write tests first, implement, document, review, verify in game.
- `ingame-verify`: writes a manual test script for you, then reads `Logs/taint.log` and SavedVariables.
- `addon-review` (forked): returns ship, revise or reject against the project's rubric.
- `perf-audit` (forked): audits code against the frequency tiers.
- `release`: you invoke it yourself; it asks before pushing.

## 2. Architecture

`docs/ARCHITECTURE.md` covers:

- **The invariant:** Blizzard's UI stays authoritative and untainted.
- **Twelve principles (P1–P12), with sourced Lattner inspiration:**
  - library-based design
  - progressive disclosure
  - safe by default
  - read → compute → apply (progressive lowering)
  - small tested changes and revert to green
  - test infrastructure as part of the product
  - diagnostics as part of the product
  - a migration path for saved data
- **Project-specific principles:**
  - "Overlay, don't own" (validated deltas)
  - probe capabilities rather than check versions
  - contain failure at the boundary
- **Structure:** module anatomy, lifecycle, storage schema and dependency direction.
- **Decision log (D1–D7):** for example, why panels are parented to `UIParent` and why the project uses its own test runner instead of busted.
- **Conformance backlog (6 ranked refactors),** each guarded by the new tests. The top two:
  - combat deferral is written three times
  - saved-data migrations are scattered, have no version, and one runs on every read

Phrases often attributed to Lattner that I couldn't source as his ("pay for what you use", "make the right thing easy") are not quoted as his.

## 3. Testing pipeline

`docs/TESTING.md` defines six tiers: static, unit, integration, invariants, bench and in-game.

- **Simulated client:** `tests/support/wow.lua` emulates the WoW client and enforces the taint contract. A test fails if the addon writes to a Blizzard table, calls a guarded Blizzard method, parents into the settings dialog, or touches a protected frame in combat.
- **Tests:** 11 unit, 68 integration (one skipped) and 5 invariant tests, plus benchmarks.
- **Tooling:** `tools/check.py` (TOC parity, a static taint lint, skill validation), a `Makefile`, `.luacheckrc` and `.editorconfig`.
- **CI:** `.github/workflows/ci.yml` runs lint, tests on Lua 5.1 and LuaJIT, the checks, and a benchmark job that can't fail the build.
- **Packaging:** `.pkgmeta` for the BigWigs packager. `make dist` builds the same file set.

## 4. Harvest from your other repos

- **agentkit:** I copied five skills unchanged (behavioral-testing, commit-discipline, debugging-methodology, function-shape, simplify-ruthless) and the conduct. I copied rather than symlinked so that cloud sessions get them too; this follows how whisperwind handles it.
  - `hot-path-budget-audit` was adapted into `perf-audit`.
  - `principle-review` was adapted into `addon-review`.
  - `architecture-canon` was translated into the project's own principles.
- **crystal:** the playbook pattern became `add-feature`; the tick-budget audit fed `perf-audit`; "verify mechanically" became the taint lint and the emulator guards.
- **devix:** the invariant test tier and the non-blocking benchmark job in CI.
- **dotfiles:** the `check-syntax.sh` hook was the template for the post-edit hook.
- **No Lua or WoW tooling exists** in any of your repos, so the harness was built from scratch.

## 5. Performance

`docs/PERFORMANCE.md` sets frequency tiers with budgets:

| Tier | Covers |
|---|---|
| T0 | load |
| T1 | interaction |
| T2 | Blizzard-driven warm paths |
| T3 | per-frame (none today) |

- **Principles:** 12, including early-out when a feature is off, coalesce to once per frame, hook the narrowest function, and allocation in proportion to how often code runs.
- **Measurement:** offline with the benchmarks and invariant tests; in game with `debugprofilestop`, `C_AddOnProfiler` and memory checks.
- **Profiler caveat:** `C_AddOnProfiler` doesn't attribute time spent in post-hooks on Blizzard functions, so it can show TinyTweaks near zero even when its hooks are expensive.
- **Known costs:** the doc lists the costs I found by reading the code. None has been measured in game yet.

## Findings to check in game

1. **Typing a size may move an offset frame.** Typing a size on a frame pinned with a non-zero offset may shift it on screen. It is the skipped test `given_a_frame_pinned_off_center_when_typing_a_size_then_it_stays_at_its_pin_on_screen`.
2. **The fine-tune box may show a stale value** after you move the slider, if Blizzard doesn't refresh the dialog.
3. **Midnight "secret anchors"** could break the arithmetic in the position module on this client. It is recorded in `taint-safety/references/hazards.md` and not yet observed.
4. **Unchecked simulator assumptions:** the 11 listed in the header of `tests/support/wow.lua` need checking against Blizzard's real code.

## Open items

- **Export Blizzard's UI source** so `blizzard-source` has the authoritative copy:
  1. Add the `-console` launch argument.
  2. On the login screen, press the backtick key.
  3. Run `ExportInterfaceFiles code`.
