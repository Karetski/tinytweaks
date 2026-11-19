---
name: ingame-verify
description: Verify a TinyTweaks change in the real WoW Forever client, the step the emulator can't replace. Writes a short click-and-look test script for the user, waits in the background for the game to log out, then reads what the dev recorder addon and the client left on disk (errors, blocked actions, taint.log, saved records checked against live frame state, a trail of the session) and reports pass/fail per step. Use after a feature or fix passes `make check`, before calling it done, when the user reports in-game misbehavior, or when the emulator's model of Blizzard is in doubt.
argument-hint: "<what changed>"
---

# ingame-verify

Change to verify: **$ARGUMENTS**

The agent can't drive the game. The user clicks and looks; everything else is recorded
automatically and read from disk. Never ask the user to type console commands, copy error
text, or say when they're done.

## What records what

```
WOW=/Applications/World of Warcraft/_forever_
$WOW/Interface/AddOns/TinyTweaks          the addon (symlink to this repo)
$WOW/Interface/AddOns/!TinyTweaksDev      dev recorder (symlink to dev/!TinyTweaksDev); never shipped
$WOW/Logs/taint.log                       taint log; the recorder turns taintLog on
$WOW/WTF/Account/<account>/SavedVariables/TinyTweaks.lua       TinyTweaksDB
$WOW/WTF/Account/<account>/SavedVariables/!TinyTweaksDev.lua   TinyTweaksDevLog, the recorder's sessions
```

The recorder (`dev/!TinyTweaksDev/Recorder.lua`) keeps, per session: build, cvars, loaded
addons; every Lua error and warning with stack and locals; blocked and forbidden actions;
slider moves; snapshots of the Edit Mode system frames (scale, alpha, point, pin, raw setting
values) and raid group positions on Edit Mode open/close, frame selection, layout updates,
combat start/end; and a final snapshot at logout, marked `logout` or `reload`.

`make ingame-report` turns that into a report: errors and blocked actions (TinyTweaks'
first), TinyTweaks blocks in taint.log, each saved typed value and offset checked against
the frame's state at logout (PASS/FAIL/INFO), the raid grid as seen on screen, and the trail.

## 1. Prepare

1. `make check` passes. If not, stop; fix it first.
2. Both links exist: `ls -la "$WOW/Interface/AddOns" | grep -i tinytweaks`. If either is
   missing, run `make link` (it only creates or updates symlinks; it needs to run outside
   the sandbox because it writes into the game folder).
3. Start the watcher in the background: `make ingame-wait` with `run_in_background`. It
   ignores `/reload` and finishes when the game logs out, printing the report. You are
   notified then; don't poll.

## 2. Write the script for the user

A short numbered list of clicks and what to look at. Start with `/reload` only when the
addon's code changed since the game loaded it (or "log in", if the game isn't running).
Then, for the change: the exact Edit Mode selection, clicks, typed values, and the expected
visible result of each step. Base expectations on Blizzard's source (`/blizzard-source`), not
on the emulator alone; the emulator has been wrong about which settings a frame has. Cover
what the tests can't: the real look of the panel, combat (a training dummy, then change
settings) and a layout switch.

End with: "`/logout` to character select. That's all; I'll take it from there." Ask the user
to mention anything that *looked* wrong (layout, overlap, wrong frame moving); errors are
recorded without them.

A second round, after the report: log back in to confirm persistence; disable TinyTweaks
in the AddOns list and log in to confirm Blizzard's own layout is intact (P1). Start
`make ingame-wait` again before each round.

## 3. Read the evidence

The watcher's output is the report. Then:

- **Errors / blocked actions**: any TinyTweaks entry is a failure; read its stack and
  locals, find the code path, apply the `taint-safety` skill. Entries from other addons
  are not ours, but say so.
- **taint.log**: any TinyTweaks block is a failure. An `ADDON_ACTION_BLOCKED` names the
  addon that tripped the protected call, which isn't always the one that introduced the
  taint; follow the chain back to the first tainted read. If the report says there is no
  taint.log and `taintLog` isn't 1, the client refused the setting; say that taint wasn't
  checked.
- **Saved records vs. frames**: every FAIL is a bug in the addon or in the check. INFO
  lines explain records that are inactive by design (slider moved, frame re-pinned).
- **TinyTweaksDB** itself: compare with the schema in `docs/ARCHITECTURE.md`; unexpected
  keys or stale or empty records are failures.
- **Trail**: match it to the script's steps (selections, slider moves, combat, layout
  switches) to see which steps the user actually ran and what each frame looked like.

## 4. Report

A table: step, expected, observed (from the trail, the checks or the user), pass/fail.
Then:

- every failure with its likely cause and the test that should have caught it; add that
  test, and if the emulator's model was wrong, fix the emulator first (P11);
- what remains unverified.

Never mark a change verified in game on the strength of the emulator alone.
