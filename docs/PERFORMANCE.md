# Performance

TinyTweaks runs in the game client's single Lua state, shared with Blizzard's UI and
every other addon. Every millisecond it spends is frame time, and every table it throws
away is garbage the shared collector must reclaim later, often during someone else's
frame. Regressions here rarely fail a test; they show up as a hitch while dragging an
Edit Mode slider, during raid roster churn, or in combat.

This document defines the budget model, the principles that keep the addon inside it,
and how cost is measured. It extends principle P6 (*pay only for what you use*) in
[ARCHITECTURE.md](ARCHITECTURE.md); [TESTING.md](TESTING.md) describes the bench and
invariant tiers that pin it. The `perf-audit` skill applies this document to a change.

## Frequency tiers

Cost matters in proportion to how often code runs. Every entry point (hook, event
handler, timer, script) belongs to one tier, and the tier sets the budget.

| Tier | Runs | Examples in TinyTweaks | Budget per call | Allocation |
|---|---|---|---|---|
| **T0 Load** | once per session or per Blizzard addon load | `ADDON_LOADED`, `Init`, panel creation, migrations | < 5 ms total for the addon | free |
| **T1 Interaction** | per player action, a few per second at most | typing a value, clicking Columns/Order/Start, selecting a frame | < 1 ms | modest |
| **T2 Warm** | driven by Blizzard, bursty: many per second during slider drags, layout passes, roster changes | `UpdateSystemSetting*`, `ApplySystemAnchor`, `LayoutFrames`, `updateLayoutFunc`, `UpdateSystems`, `UpdateSettings` post-hooks | < 0.1 ms when the feature is off; < 0.5 ms when it acts | none when off; bounded and small when on |
| **T3 Hot** | every frame or per high-frequency event (`OnUpdate`, `COMBAT_LOG_EVENT_UNFILTERED`, `UNIT_AURA`) | none today | design review required | none |

Budgets are targets for the in-game measurement below; the offline bench reports trends,
not client numbers.

## Principles

1. **Event-driven, never polling.** React to Blizzard hooks and events. An `OnUpdate`
   (T3) needs a design reason the decision log records, runs only while its frame is
   shown, and is throttled.
2. **Hook the narrowest, least frequent function that guarantees correctness.** Post-hook
   the call that ends a Blizzard pass, not the one inside its loop.
   `CompactRaidFrameContainer:LayoutFrames` runs once per re-flow;
   `FlowContainer_DoLayout` ran dozens of times per slider step. Before hooking, find
   out how often the function runs (`/blizzard-source`).
3. **Early-out when off.** The first statement of a T2 hook is a cheap check that the
   feature applies (enabled, right mode, right frame). A disabled feature costs a branch.
4. **Coalesce bursts to one run per frame.** Set a flag and schedule with
   `C_Timer.After(0, …)`; key pending work by frame so repeats collapse
   (`ScheduleRefresh` is the model).
5. **Skip work whose inputs didn't change**, with a change check that is itself cheap
   and doesn't allocate.
6. **Allocation is proportional to frequency.** T0/T1 may allocate freely. T2 paths
   reuse tables, avoid closures, and avoid string building (`..`, `format`) for keys and
   comparisons. Saved-variable migration and default-filling happen at load, never per
   read.
7. **Widget calls are the expensive part.** They cross into the client and can
   invalidate layout. Don't repeat `ClearAllPoints`/`SetPoint`/`SetScale`/`SetSize` with
   unchanged values on T2 paths.
8. **Build UI once.** Frames can't be deleted or garbage-collected, so a frame created per
   update is a permanent leak. Panels and their widgets are created once and refreshed;
   repeated widgets come from a pool (`CreateFramePool`) or a fixed array.
9. **Bounded work.** Iterate the changed frame, not every registered system frame; the 8
   groups, not every raid member, unless the layout truly needs members.
10. **Combat is a budget too.** Protected work is deferred, never retried in a loop; the
    pending set is keyed and drained once at `PLAYER_REGEN_ENABLED`.
11. **Measure before optimizing.** Structural choices (tiers, hooks, coalescing) are
    design and need no measurement. Micro-optimizations need a measurement that points
    at them, and belong only on T3 paths. That includes caching globals in locals: real
    in tight loops, according to Lua's authors, and noise everywhere else.
12. **Narrow event registration.** Register only the events in use. For unit events, use
    `RegisterUnitEvent` (up to four units) rather than filtering a global event in Lua.

## Measuring

### Offline: `make bench` and the invariant tier

`make bench` runs the benches in `tests/bench/` under LuaJIT against the emulator and
reports, per operation, time and kilobytes allocated (garbage collection stopped,
`collectgarbage("count")` deltas). The emulator's widgets are cheaper than the client's
and LuaJIT is faster than the client's Lua, so:

- **allocation per op** is reliable and comparable across commits;
- **time per op** is for comparing commits on the same machine, not for client budgets.

Properties worth keeping are pinned as tests in `tests/invariants/` (for example: a
refresh with unchanged group sizes is skipped; a reflow allocates under a fixed ceiling).
An invariant failing means the change is wrong, not the invariant; raise a ceiling only
with a measurement and a reason in the test.

### In game

Run these from the chat box. `/run` executes Lua; `/dump` prints a value.

- **Time one call:**
  `/run local t=debugprofilestop() <call> print(debugprofilestop()-t)` (milliseconds).
  Take deltas only; never call `debugprofilestart`, because the timer is shared.
- **Addon CPU over time:** the client's add-on profiler (`C_AddOnProfiler`, retail
  11.0.7+; probe for it):
  `/dump C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric("TinyTweaks", Enum.AddOnProfilerMetric.RecentAverageTime)`.
  **Caveat:** the profiler attributes time to the addon that owns the frame, and doesn't
  track code paths that start in secure Blizzard code. Most TinyTweaks work runs in
  post-hooks on Blizzard functions, so the profiler can report near zero while the
  hooks are expensive. For hook cost, instrument with `debugprofilestop` instead.
- **Memory:** `/run UpdateAddOnMemoryUsage() print(GetAddOnMemoryUsage("TinyTweaks"))`
  (kilobytes; `GetAddOnMemoryUsage` returns the value cached by the last update). Repeat
  during a slider drag or roster churn: steady growth between collections is garbage
  being produced on a warm path.
- **Reproducible scenarios:** drag a fine-tunable slider end to end; drag a frame across
  the screen with snapping; toggle raid frame settings with the grid on in a full raid
  (or with Edit Mode's raid frame preview); switch layouts. Measure with the feature off
  and on.

The `perf-audit` skill turns this into a per-path verdict; record in-game numbers in the
commit message of any change that claims a performance win.

Sources: warcraft.wiki.gg pages for `C_AddOnProfiler.GetAddOnMetric`,
`debugprofilestop`, `GetAddOnMemoryUsage`, `CreateFrame`, `RegisterUnitEvent`; Roberto
Ierusalimschy, "Lua Performance Tips" (*Lua Programming Gems*).

## Known costs

Observed by reading the code; none measured in game yet. Each is a candidate only if
measurement shows it matters.

- `RaidGroupGrid` `GetConfig` runs the settings migration and fills defaults on every
  call, and `IsActive` (called from T2 hooks) calls it. Moving migration to load time is
  backlog item 3 in ARCHITECTURE.md.
- `RaidGroupGrid` builds group-size strings (`w .. "x" .. h`) to detect size changes, and
  builds a cell table plus closures per reflow.
- Several hooks call `UpdatePanel` for one user action (backlog item 6).
- `EditModeFineTune` `RestoreApplied` iterates every frame it has ever applied on each
  `UpdateSystems`; bounded by the number of supported frames, so acceptable.
- `EditModeFineTune` post-hooks `ApplySystemAnchor` (which runs per frame on each layout update,
  reset or revert, not per slider step). Each call looks up the frame's typed values, which builds
  the layout and system key strings, about 0.6 KB per call in the bench. Caching the layout key in
  `Core` would remove most of it, if measurement ever shows that it matters.
