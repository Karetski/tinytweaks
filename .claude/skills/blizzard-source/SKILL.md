---
name: blizzard-source
description: Answer a question about how Blizzard's UI code behaves on the WoW Forever client (Interface 16001) by reading Blizzard's Lua/XML source, and return a short, cited answer. Use before hooking a Blizzard function, when choosing which function to post-hook, when checking what a Blizzard handler does (which widget calls, which conditions), when the emulator's model of a Blizzard object needs to change, or when in-game behavior disagrees with expectations. Pass the question as the argument.
argument-hint: "<question about Blizzard UI behavior>"
context: fork
agent: Explore
---

# blizzard-source

Answer this question about Blizzard's UI code: **$ARGUMENTS**

You are researching for an addon that must never run or modify Blizzard code (see the
taint contract in `.claude/skills/taint-safety/SKILL.md`). The answer decides which
function the addon post-hooks and which widget calls it may repeat, so precision matters
more than breadth.

## Where the source is

Search in this order and say which one you used:

1. **Exported client source (authoritative for the installed build).** Look in
   `/Applications/World of Warcraft/_forever_/BlizzardInterfaceCode/Interface/`
   (`AddOns/Blizzard_*` folders). The client writes it when the player runs
   `ExportInterfaceFiles code` in the real game console. The `/console` slash command
   doesn't work for this. The console must be enabled with the `-console` launch
   argument (Battle.net → Settings → Game Settings → additional command line arguments)
   and opened with the backtick key on the login or character-select screen. If the
   folder is missing, mention that in the answer and continue with source 2.
2. **Public mirror, `forever` branch**: the `Gethe/wow-ui-source` repository tracks this
   client on its `forever` branch. Use
   `gh api "repos/Gethe/wow-ui-source/contents/<path>?ref=forever" --jq .content | base64 -d`
   to read a file, or a shallow clone into the scratchpad for wide searches:
   `git clone --depth 1 --branch forever https://github.com/Gethe/wow-ui-source <scratch>/wow-ui-source`.
   Check the build in the branch's latest commit message against the client's; when they
   differ, say so. Never use the `live` (retail) branch for this client without labeling
   it as retail.
3. **The project's own record**: the emulator in `tests/support/wow.lua` (its header
   lists assumptions about Blizzard behavior) and
   `.claude/skills/taint-safety/references/hazards.md`. These are models and history,
   not source.

Useful entry points for this project: `Blizzard_EditMode` (`EditModeManager.lua`,
`EditModeSystemTemplates.lua`, `EditModeDialogs.lua`, `EditModeSettingDisplayInfo.lua`,
`EditModeUtil.lua`, magnetism manager) and `Blizzard_CompactRaidFrames`
(`Blizzard_CompactRaidFrameContainer.lua`, `Blizzard_CompactRaidGroup.lua`,
`FlowContainer.lua` in `Blizzard_SharedXML`). Search by symbol (`grep -rn
"function EditModeSystemMixin:ApplySystemAnchor"`) rather than reading whole files.

## What to return

Keep it under ~40 lines:

1. **Answer** in two or three sentences.
2. **Evidence**: file path and line numbers for each claim, with the minimal code
   excerpt (a few lines) that proves it.
3. **Call path**, when relevant: who calls the function, how often (once per user action,
   per slider step, per layout pass, per frame), and in which state (combat, Edit Mode
   open, initialization).
4. **Taint notes**: does the path read anything an addon could write? Which calls would
   run Blizzard code if repeated from the addon?
5. **Source used** (exported, mirror, or model) and anything you could not verify.

Do not edit files. Do not guess: if the source does not settle the question, say what is
missing.
