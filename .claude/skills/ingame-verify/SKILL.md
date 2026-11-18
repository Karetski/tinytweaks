---
name: ingame-verify
description: Verify a TinyTweaks change in the real WoW Forever client, the step the emulator can't replace. Prepares a numbered manual test script for the user (install link, taint logging, exact clicks and expected results), then reads the evidence the client leaves on disk (taint.log, SavedVariables) and reports pass/fail per step. Use after a feature or fix passes `make check`, before calling it done, when the user reports in-game misbehavior, or when the emulator's model of Blizzard is in doubt.
argument-hint: "<what changed>"
---

# ingame-verify

Change to verify: **$ARGUMENTS**

The agent can't drive the game. This skill splits the work: the agent writes a precise
script, the user runs it, and the agent reads what the client wrote to disk.

## Paths

```
WOW=/Applications/World of Warcraft/_forever_
$WOW/Interface/AddOns/TinyTweaks          the addon (symlink to this repo: `make link`)
$WOW/Logs/taint.log                       taint log, when enabled
$WOW/WTF/Account/<account>/SavedVariables/TinyTweaks.lua    TinyTweaksDB, written on /reload or logout
$WOW/Errors/                              crash dumps (not Lua errors)
```

## 1. Prepare

1. `make check` passes. If not, stop; fix it first.
2. Confirm the addon is linked: `ls -la "$WOW/Interface/AddOns/TinyTweaks"`. If it isn't
   linked, tell the user to run `make link` (it refuses to overwrite a real folder).
3. Note the current size and modification time of `taint.log` and the SavedVariables
   file, so you only read what this session adds.

## 2. Write the script for the user

A numbered list the user can follow without thinking. Always start with:

1. `/console taintLog 1` (records taint; `2` is verbose; heavy, so it's turned off at
   the end).
2. `/console scriptErrors 1` (shows Lua errors in a dialog), then `/reload` once so
   logging starts from a clean UI.

Then, for the change: the exact Edit Mode selection, clicks, typed values, and the
expected visible result of each step. Cover the paths the tests cover and the ones they
can't: the real look of the panel, combat (`/duel` a friend or fight a training dummy,
then change roster or settings) and a layout switch. Put the steps that need a reload in
a second round, run after you have read the taint log: logging back in to confirm
persistence, and disabling TinyTweaks in the AddOns list to confirm Blizzard's own
layout is intact (P1).

Ask the user to report any Lua error dialog verbatim. End with `/logout` (or `/camp`) to
the character-select screen, **not** `/reload`: logging out writes both SavedVariables and
the taint log, while a reload starts a fresh taint log. After you have read the
evidence, the user turns logging off with `/console taintLog 0` (it is costly to leave on).

## 3. Read the evidence

- **taint.log**: search the new part for `TinyTweaks`. Any line where TinyTweaks
  taints a Blizzard execution path is a failure; quote it, identify the code path and
  apply the `taint-safety` skill. Lines naming other addons are not ours, but say so.
  An `ADDON_ACTION_BLOCKED` names the addon that tripped the protected call, which isn't
  always the one that introduced the taint; follow the log's chain back to the first
  tainted read.
- **SavedVariables**: read `TinyTweaksDB` and check that it matches the schema in
  `docs/ARCHITECTURE.md` and the values the script set (layout key, overrides, offsets,
  grid settings). Unexpected keys or stale records are failures.

## 4. Report

A table: step, expected, observed (from the user or from disk), pass/fail. Then:

- every failure with its likely cause and the test that should have caught it; add that
  test, and if the emulator's model was wrong, fix the emulator first (P11);
- what remains unverified.

Never mark a change verified in game on the strength of the emulator alone.
