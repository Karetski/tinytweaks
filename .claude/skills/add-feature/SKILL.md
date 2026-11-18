---
name: add-feature
description: The end-to-end procedure for adding or substantially changing a TinyTweaks feature (a tweak to the native UI): design against the architecture principles, research the Blizzard code it touches, model that code in the emulator, write the behavioral tests first, implement the module in the standard shape, then document, check and verify in game. Use when starting a new tweak or module, adding a setting or panel to an existing one, or changing what a feature stores in SavedVariables.
argument-hint: "<feature description>"
---

# add-feature

Feature to build: **$ARGUMENTS**

Work through the phases in order. Each ends with a check you can observe; don't move on
until it passes. Present the plan from phase 1 to the user before writing code: the shape
of a feature (what it stores, where its controls appear, what it hooks) is their call.

## 1. Design → verify: every question has an answer

Answer these in a short plan. A question with no answer means the design isn't ready.

- **What does the player see, and where?** Controls live next to the Edit Mode dialog of
  the frame they affect (decision D1). What is the default? (It must be Blizzard's own
  behavior.) What does the panel say when the feature can't apply, and why?
- **What does Blizzard own, and what is the overlay?** (P1) Which Blizzard value is each
  stored delta made against, and when does it invalidate?
- **What will it hook?** Name each Blizzard function, how often it runs, and confirm it
  is a post-hook (P2, P6). Use the `blizzard-source` skill for each one.
- **Which widget calls will it make, on which frames?** Are any protected (combat)?
- **What does it store?** Extend the schema in `docs/ARCHITECTURE.md`. Is an old format
  being replaced? Then a migration is part of the feature (P9).
- **What's the frequency tier of each code path?** (`docs/PERFORMANCE.md`)

## 2. Research → verify: each hook is backed by source

Run `/blizzard-source <question>` for each function you plan to hook or whose widget call
you'll repeat. Record file and line references in the plan. If the exported client source
is missing, ask the user to export it before relying on the public mirror for anything
taint-relevant.

## 3. Model → verify: the emulator reproduces Blizzard's behavior

Extend `tests/support/wow.lua` with the Blizzard objects and methods the feature touches,
following the source from phase 2. List each new assumption in the emulator's header and
add the methods that change Blizzard state to the guard lists, so an accidental call
from the addon fails the tests. See `docs/TESTING.md` for the emulator's conventions.

## 4. Tests first → verify: they fail for the right reason

Write the integration scenarios in `tests/integration/<feature>_spec.lua`
(`given_<setup>_when_<action>_then_<outcome>`), covering at least:

- the default state does nothing (Blizzard's layout untouched);
- the main interaction applies the change;
- the Blizzard change that invalidates the overlay drops it;
- layout switch, combat deferral (if protected frames), and reload (a new world from the
  saved table);
- the panel's disabled and explanatory states;
- a migration from each old saved format.

Pure compute functions get unit tests in `tests/unit/`. Run `make test`; the new tests
must fail because the feature is missing, not because of a harness error.

## 5. Implement → verify: `make check` is green

- One module file, standard anatomy (`docs/ARCHITECTURE.md`, *Module anatomy*): doc block
  with model and **Taint notes**, storage accessors, pure compute, apply, hooks, panel,
  `Init`.
- Add the file to `TinyTweaks.toc` after `Core.lua`.
- Depend only on `Core` (P3). A helper that would be the third copy moves to `Core` in a
  separate commit first.
- Follow `.claude/skills/taint-safety/SKILL.md` line by line.

## 6. Document → verify: a cold read stands alone

- `README.md`: a feature section in the existing voice (short, plain, player-facing,
  with *Limitations* if any).
- `docs/ARCHITECTURE.md`: storage schema; a decision-log entry for any non-obvious choice.
- `CHANGELOG.md`: an entry under *Unreleased*.

## 7. Review → verify: ship verdicts

Run `/addon-review` on the change, and `/perf-audit` if it adds or changes a hook, an event
handler or anything in tier T2 or above. Fix every blocker.

## 8. Verify in game → verify: the user confirms

Run `/ingame-verify` to produce the checklist, hand it to the user, and read the taint
log and SavedVariables afterwards. Until this passes, say plainly that the feature is
verified against the emulator only.

## 9. Commit

Small commits, each green: emulator extension, tests plus feature, docs. Refactors that the
feature needed land before it in their own commits.
