#!/usr/bin/env python3
"""Mechanical repository checks. Stdlib only. Run from anywhere:

    python3 tools/check.py                 all checks
    python3 tools/check.py --only taint    one check: toc | taint | skills

Exits non-zero if any ERROR is found. WARNINGs are printed but don't fail.

toc     The TOC is the addon's manifest: every listed file exists, every addon *.lua at the
        repository root is listed (a file missing from the TOC silently never loads), and the
        Interface and Version fields are present.

taint   The taint contract, as far as text can check it (the simulated client in tests/ enforces
        it at runtime). Over the addon's sources, outside comments:
          - SetScript on a Blizzard global, or on a local alias of one (use HookScript)
          - assigning a field on a Blizzard global or an alias (never write Blizzard tables)
          - calling a Blizzard method that changes Edit Mode / raid layout state (hook it with
            hooksecurefunc instead of calling it)
          - CreateFrame parented to EditModeSystemSettingsDialog or MinimapCluster (they iterate
            their children)
          - SettingsPanel:Open / :OpenToCategory (use Settings.OpenToCategory, which opens it securely)
          - a global function or global assignment at file scope (everything is local or on ns)
        The dev recorder addon (dev/!TinyTweaksDev) is checked under the same rules.
        A line can opt out with a trailing comment:  -- taint-ok: <reason>

skills  Every .claude/skills/<name>/SKILL.md has frontmatter with name == directory name
        (^[a-z0-9-]+$, <= 64 chars), a non-empty description (+ when_to_use) <= 1536 chars,
        context == fork when present; unknown frontmatter keys warn. Every skill is named in
        CLAUDE.md, so the index agents read can't drift from the skills that exist.
"""

import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOC = os.path.join(ROOT, "TinyTweaks.toc")
DEV_TOC = os.path.join(ROOT, "dev", "!TinyTweaksDev", "!TinyTweaksDev.toc")

errors = []
warnings = []


def error(where, message):
    errors.append(f"ERROR {where}: {message}")


def warn(where, message):
    warnings.append(f"WARNING {where}: {message}")


def rel(path):
    return os.path.relpath(path, ROOT)


# TOC -----------------------------------------------------------------------------------------

def toc_files(toc=TOC):
    files, fields = [], {}
    with open(toc, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            m = re.match(r"^##\s*([^:]+):\s*(.*)$", line)
            if m:
                fields[m.group(1).strip()] = m.group(2).strip()
            elif not line.startswith("#"):
                files.append(line.replace("\\", "/"))
    return files, fields


def check_toc():
    if not os.path.exists(TOC):
        error("TinyTweaks.toc", "missing")
        return
    files, fields = toc_files()
    for key in ("Interface", "Title", "Version"):
        if not fields.get(key):
            error("TinyTweaks.toc", f"missing ## {key}")
    if fields.get("Interface") and not re.fullmatch(r"\d+(\s*,\s*\d+)*", fields["Interface"]):
        error("TinyTweaks.toc", f"Interface is not a number list: {fields['Interface']}")
    for f in files:
        if not os.path.isfile(os.path.join(ROOT, f)):
            error("TinyTweaks.toc", f"lists {f}, which doesn't exist")
    listed = set(files)
    for name in sorted(os.listdir(ROOT)):
        if name.endswith(".lua") and not name.startswith(".") and name not in listed:
            error(name, "addon file is not listed in TinyTweaks.toc (it would never load)")
    if len(listed) != len(files):
        error("TinyTweaks.toc", "lists a file twice")


# Taint contract ------------------------------------------------------------------------------

BLIZZARD_GLOBALS = {
    "EditModeManagerFrame", "EditModeSystemSettingsDialog", "CompactRaidFrameContainer", "UIParent",
    "GameTooltip", "UIErrorsFrame", "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame",
    "Minimap", "ObjectiveTrackerFrame", "ChatFrame1", "MainMenuBar", "BuffFrame", "DebuffFrame",
    "PlayerCastingBarFrame", "PartyFrame", "BossTargetFrameContainer", "MinimapCluster",
    "SettingsPanel", "Settings",
}
LAYOUT_PARENTS = {"EditModeSystemSettingsDialog", "MinimapCluster"}

# SettingsPanel methods that open it through ShowUIPanel. Called from addon code they run the whole
# panel path tainted; Settings.OpenToCategory opens it as secure code instead.
SETTINGS_PANEL_OPENERS = {"Open", "OpenToCategory"}

# Blizzard methods that change Edit Mode / raid layout state. Calling them from addon code runs
# Blizzard's code tainted; TinyTweaks post-hooks them instead.
STATE_CHANGING_METHODS = {
    "ApplySystemAnchor", "OnSystemPositionChange", "SnapToFrame", "OnSettingValueChanged",
    "UpdateSystems", "UpdateSystem", "UpdateRaidContainerFlow", "LayoutFrames",
    "AttachToSystemFrame", "UpdateSettings", "UpdateDialog", "RegisterSystemFrame",
    "SetSettingValue", "UpdateSystemSetting", "OnSystemSettingChange", "SaveLayouts",
    "SelectLayout", "SetActiveLayout", "RevertAllChanges", "ResetToDefaultPosition",
    "ClearFrameSnap", "SetSelected", "ClearHighlight", "UpdateLayoutInfo",
}
STATE_CHANGING_PATTERN = re.compile(
    r"[:.](" + "|".join(sorted(STATE_CHANGING_METHODS)) + r"|UpdateSystemSetting\w+)\s*\("
)
ESCAPE = re.compile(r"--\s*taint-ok:\s*\S")


def strip_comments_and_strings(source):
    """Blank out comments and string contents, keeping line structure and code columns."""
    out = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if source.startswith("--", i):
            m = re.match(r"--\[(=*)\[", source[i:])
            if m:
                end = source.find("]" + m.group(1) + "]", i)
                end = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = source.find("\n", i)
                end = n if end < 0 else end
            out.append(re.sub(r"[^\n]", " ", source[i:end]))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and source[j] != c and source[j] != "\n":
                j += 2 if source[j] == "\\" else 1
            out.append(c + " " * (j - i - 1) + (c if j < n else ""))
            i = j + 1
        elif source.startswith("[[", i) or re.match(r"\[=+\[", source[i:]):
            m = re.match(r"\[(=*)\[", source[i:])
            end = source.find("]" + m.group(1) + "]", i)
            end = n if end < 0 else end + len(m.group(1)) + 2
            out.append(re.sub(r"[^\n]", " ", source[i:end]))
            i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)


def addon_sources():
    """The addon's sources and the dev recorder's: both run in the client under the same contract."""
    sources = []
    for toc in (TOC, DEV_TOC):
        if not os.path.exists(toc):
            continue
        base = os.path.dirname(toc)
        files, _ = toc_files(toc)
        sources += [os.path.join(base, f) for f in files if f.endswith(".lua") and os.path.isfile(os.path.join(base, f))]
    return sources


def check_taint():
    for path in addon_sources():
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        code = strip_comments_and_strings(raw)
        raw_lines = raw.split("\n")
        code_lines = code.split("\n")
        blizzard = set(BLIZZARD_GLOBALS)
        layout_parents = set(LAYOUT_PARENTS)
        settings_panels = {"SettingsPanel"}
        for line in code_lines:
            m = re.match(r"\s*local\s+(\w+)\s*=\s*(\w+)\s*$", line)
            if m and m.group(2) in blizzard:
                blizzard.add(m.group(1))
                if m.group(2) in layout_parents:
                    layout_parents.add(m.group(1))
                if m.group(2) in settings_panels:
                    settings_panels.add(m.group(1))
        # File-scope locals, including forward declarations (`local Foo` assigned further down).
        file_locals = set()
        for line in code_lines:
            m = re.match(r"local\s+(?:function\s+)?([\w\s,]+?)\s*(?:=|\(|$)", line)
            if m:
                file_locals.update(name.strip() for name in m.group(1).split(","))
        names = "|".join(sorted(blizzard))
        set_script = re.compile(r"\b(" + names + r")\s*:\s*SetScript\s*\(")
        field_write = re.compile(r"\b(" + names + r")((?:\.\w+|\[[^\]]+\])+)\s*=(?!=)")
        parent_names = "|".join(sorted(layout_parents))
        create_parented = re.compile(r"\bCreateFrame\s*\([^,()]*,[^,()]*,\s*(" + parent_names + r")\b")
        panel_open = re.compile(
            r"\b(" + "|".join(sorted(settings_panels)) + r")\s*[:.]\s*(" + "|".join(sorted(SETTINGS_PANEL_OPENERS)) + r")\s*\("
        )

        for number, line in enumerate(code_lines, 1):
            if ESCAPE.search(raw_lines[number - 1]):
                continue
            where = f"{rel(path)}:{number}"
            m = set_script.search(line)
            if m:
                error(where, f"SetScript on Blizzard frame {m.group(1)} replaces Blizzard's handler; use HookScript")
            m = field_write.search(line)
            if m and not line.lstrip().startswith("local "):
                error(where, f"writes {m.group(1)}{m.group(2)}: never write fields on Blizzard frames or tables")
            m = STATE_CHANGING_PATTERN.search(line)
            if m:
                error(where, f"calls Blizzard state-changing method {m.group(1)}: post-hook it with hooksecurefunc instead")
            m = create_parented.search(line)
            if m:
                error(where, f"CreateFrame parented to {m.group(1)}: parent to UIParent and anchor instead")
            m = panel_open.search(line)
            if m:
                error(where, f"calls {m.group(1)}:{m.group(2)}, which opens the panel tainted: use Settings.OpenToCategory(category:GetID())")
            m = re.match(r"function\s+([A-Za-z_]\w*)\s*\(", line)
            if m and m.group(1) not in file_locals:
                error(where, "global function at file scope: make it local or a field of ns/the module")
            m = re.match(r"([A-Za-z_]\w*)\s*=(?!=)", line)
            if m and m.group(1) != "TinyTweaksDB" and m.group(1) not in file_locals:
                error(where, f"global assignment to {m.group(1)} at file scope: make it local")


# Skills ----------------------------------------------------------------------------------------

KNOWN_KEYS = {
    "name", "description", "when_to_use", "argument-hint", "arguments", "disable-model-invocation",
    "user-invocable", "allowed-tools", "disallowed-tools", "model", "effort", "context", "agent",
    "background", "hooks", "paths", "shell", "metadata", "license", "compatibility",
}
NAME_RE = re.compile(r"^[a-z0-9-]+$")
DESC_MAX = 1536


def parse_frontmatter(text):
    """Top-level keys of a simple YAML frontmatter block; continuation lines join their key."""
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end < 0:
        return None
    fields, key = {}, None
    for line in text[3:end].strip("\n").split("\n"):
        m = re.match(r"^([A-Za-z_][\w-]*)\s*:\s*(.*)$", line)
        if m and not line.startswith((" ", "\t")):
            key = m.group(1)
            fields[key] = m.group(2).strip()
        elif key is not None:
            fields[key] = (fields[key] + " " + line.strip()).strip()
    for k, v in fields.items():
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            fields[k] = v[1:-1]
        elif v in (">", "|", ">-", "|-"):
            fields[k] = ""
    return fields


def check_skills():
    skills_dir = os.path.join(ROOT, ".claude", "skills")
    if not os.path.isdir(skills_dir):
        return
    claude_md = os.path.join(ROOT, "CLAUDE.md")
    index = open(claude_md, encoding="utf-8").read() if os.path.exists(claude_md) else ""
    for name in sorted(os.listdir(skills_dir)):
        directory = os.path.join(skills_dir, name)
        if not os.path.isdir(directory):
            continue
        path = os.path.join(directory, "SKILL.md")
        where = rel(path)
        if not os.path.isfile(path):
            error(rel(directory), "skill directory without SKILL.md")
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        fields = parse_frontmatter(text)
        if fields is None:
            error(where, "missing frontmatter (--- ... ---)")
            continue
        for key in fields:
            if key not in KNOWN_KEYS:
                warn(where, f"unknown frontmatter key '{key}' (typo?)")
        skill_name = fields.get("name", "")
        if not skill_name:
            error(where, "missing name")
        elif skill_name != name:
            error(where, f"name '{skill_name}' doesn't match directory '{name}'")
        elif not NAME_RE.match(skill_name) or len(skill_name) > 64:
            error(where, f"name '{skill_name}' must match ^[a-z0-9-]+$ and be <= 64 chars")
        description = fields.get("description", "")
        if not description:
            error(where, "missing description")
        total = len(description) + len(fields.get("when_to_use", ""))
        if total > DESC_MAX:
            error(where, f"description + when_to_use is {total} chars (max {DESC_MAX})")
        if "context" in fields and fields["context"] != "fork":
            error(where, f"context must be 'fork', got '{fields['context']}'")
        if not re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", index):
            error(where, f"skill '{name}' is not named in CLAUDE.md")


# Main --------------------------------------------------------------------------------------------

CHECKS = {"toc": check_toc, "taint": check_taint, "skills": check_skills}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", choices=sorted(CHECKS), action="append")
    args = parser.parse_args()
    for name in args.only or list(CHECKS):
        CHECKS[name]()
    for line in warnings + errors:
        print(line)
    if errors:
        print(f"{len(errors)} error(s)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
