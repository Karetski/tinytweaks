---
name: addon-review
description: Review a TinyTweaks change (the working-tree diff by default, or a commit range or branch passed as the argument) against the project's own rubric — the taint contract, the architecture principles P1-P12, the performance tiers, test coverage in the emulator, and docs/storage consistency — and end with a ship / revise / reject verdict. Use before committing a feature or fix, when asked "is this ready" or "does this fit the design", or after another agent produced a change.
argument-hint: "[git range or branch; default: uncommitted changes]"
context: fork
agent: general-purpose
---

# addon-review

Review target: **$ARGUMENTS** (empty means the uncommitted diff: `git diff HEAD` plus
untracked files from `git status --porcelain`).

You review a World of Warcraft addon that runs inside Blizzard's secure UI. Read these
first; they are the rubric, not your memory of good practice:

1. `docs/ARCHITECTURE.md`: the invariant, principles P1-P12, module anatomy, storage schema, decision log.
2. `.claude/skills/taint-safety/SKILL.md`: the taint contract and its red flags.
3. `docs/PERFORMANCE.md`: frequency tiers and budgets.
4. `docs/TESTING.md`: tiers and what each change must carry.

Then read the full diff and every touched file in full (context around a hunk matters
for taint: where did this frame come from?).

## Passes

Run each pass. Report only findings that hold up after you re-read the code.

1. **Mechanical gate.** Run `make check` and report the result verbatim if it fails.
2. **Taint.** For every line that touches a Blizzard object: where did the object come
   from, is this a read, a widget call or a forbidden write/call? Is every protected-frame
   path combat-guarded? Any new global? Every taint finding is a blocker.
3. **Principles.** Walk P1-P12. One short paragraph for each principle the change
   engages with: upholds, bends or breaks. Skip the rest.
4. **Performance.** For each new or changed hook or event handler: its tier, early-out
   when the feature is off, allocations per call, coalescing. Escalate to `perf-audit`
   when a path is T2 or hotter and non-trivial.
5. **Tests.** Does every behavior change come with an integration scenario? Did the
   emulator gain the Blizzard methods the code now touches, with state-changing ones on
   the guard lists and assumptions in its header? Would the tests fail if the change were
   reverted? Is there a migration test for any storage change?
6. **Storage and docs.** Schema in `docs/ARCHITECTURE.md` matches the code; README feature
   text matches behavior; CHANGELOG entry present for user-visible changes; module doc
   block and taint notes updated.
7. **Shape.** Module anatomy order; dependency direction (modules depend only on Core);
   duplicated helpers (third copy → Core); commits that mix refactor and behavior.

## Output

```
## Verdict: ship | revise | reject

### Blockers
- <file>:<line> — <rule broken> — <what secure code / the player will hit> — <fix>

### Should fix
- ...

### Principles
- P<n> <name>: upholds | bends | breaks — <one or two sentences>

### Tests and docs
- ...

### Not verified
- what this review could not establish (e.g. in-game behavior, Blizzard source not exported)
```

`reject` means the approach is wrong (e.g. it requires calling Blizzard code); `revise`
means fixable findings; `ship` means no blockers. Be direct: name the rule and the line.
Do not edit files.
