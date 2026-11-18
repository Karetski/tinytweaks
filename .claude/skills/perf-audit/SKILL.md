---
name: perf-audit
description: Static performance audit of TinyTweaks code paths against the frequency tiers and budgets in docs/PERFORMANCE.md. Enumerates every hook, event handler, timer and script on the path, classifies how often each runs (load, interaction, Blizzard-driven warm path, per-frame), flags work that is unbounded, uncoalesced, allocating on warm paths or running while the feature is off, and returns a green/yellow/red verdict per unit plus the bench or invariant that should pin it. Use when adding or changing a hook, event handler, OnUpdate or C_Timer, when Edit Mode or raid frames feel sluggish, or before release.
argument-hint: "[file, function, or git range; default: uncommitted changes]"
context: fork
agent: general-purpose
---

# perf-audit

Audit target: **$ARGUMENTS** (empty means the uncommitted diff; `all` means the whole
addon).

Read `docs/PERFORMANCE.md` first: it defines the tiers (T0 load, T1 interaction, T2
Blizzard-driven warm paths, T3 per-frame / high-frequency events) and their budgets. The
addon runs inside the game client's single Lua state, shared with Blizzard's UI and every
other addon: time and garbage spent here are frame time and GC work charged to everyone.
Regressions rarely fail tests; they show up as hitching in Edit Mode, during raid roster
churn or in combat.

## Steps

1. **Enumerate entry points.** List every `hooksecurefunc`, `HookScript`, `SetScript`,
   `ns:On(event)`, `C_Timer` call and `OnUpdate` in the target. For each, find the
   Blizzard caller (use `/blizzard-source` when unsure) and state how often it fires and
   when: once at load, per user action, per slider step, per Blizzard layout pass, per
   roster change, per frame. Assign a tier.

2. **Walk each path** from the entry point through every function it calls, and flag:
   - **No early-out when the feature is off.** The first work in a hook should be a
     cheap check (P6: a disabled feature costs a branch).
   - **Uncoalesced bursts.** Work that can fire many times per frame (slider drags,
     layout passes, roster updates) and isn't collapsed to one run per frame
     (`C_Timer.After(0)` plus a scheduled flag) or deduplicated by key.
   - **Allocation on T2/T3 paths.** Table constructors, closures, string concatenation
     or `format` per call; saved-variable migration or default-filling per read.
   - **Unbounded or repeated work.** Iterating every registered system frame or every
     raid member when one changed; redoing work whose inputs didn't change (look for a
     cheap change check, and check that the check itself doesn't allocate).
   - **Redundant widget calls.** `ClearAllPoints`/`SetPoint`/`SetScale`/`SetSize` with
     unchanged values; these invalidate layout in the client.
   - **Panel updates** triggered by several hooks for one user action.
   - **Combat:** any work for protected frames in combat (it must be deferred, and the
     pending set must be keyed so it stays bounded).
   - **T3 anything.** `OnUpdate`, `COMBAT_LOG_EVENT_UNFILTERED`, `UNIT_AURA` and similar
     need an explicit design reason, a throttle and an invariant test. Prefer
     `RegisterUnitEvent` to global unit events.

3. **Estimate cost.** For each unit: "per call: O(…) over N = <groups/members/frames>,
   allocates <tables/strings>". Check against the tier budget.

4. **Measure what you can.** Run `make bench` and quote the numbers for the touched
   paths (time per op and KB allocated per op). The bench runs under LuaJIT with the
   emulator, so trust trends and allocation counts more than absolute times. If a
   touched path has no bench, say which bench to add.

## Output

Per unit:

```
<entry point> → <function chain>   tier T<n>   🟢 | 🟡 | 🔴
  frequency: …
  cost: …
  finding: …            (omit when green)
  pin: <bench or invariant test that would catch a regression>
```

- 🟢 within budget, early-outs when off, coalesced, no allocation on T2/T3.
- 🟡 within budget today but allocates on a T2 path, lacks a pin, or relies on an
  undocumented "Blizzard only calls this once" assumption.
- 🔴 unbounded, uncoalesced on T2/T3, works while the feature is off on T2/T3, or touches
  protected frames in combat. Must be fixed before merge.

Take the most severe tier when a unit trips several. End with the list of 🔴 items and the
benches or invariants to add. Never recommend speculative micro-optimizations (caching
globals in locals, etc.) on paths below T3 or without a measurement. Do not edit files.
