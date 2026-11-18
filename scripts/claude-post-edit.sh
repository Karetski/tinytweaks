#!/bin/sh
# Claude Code PostToolUse hook (Edit|Write|MultiEdit): fast feedback after every file edit.
#
#   *.lua                       syntax check, luacheck on the file (if installed), then the fast
#                               test tiers (unit + integration + invariants)
#   *.toc, .claude/skills/*     tools/check.py
#
# Exit 0 silently when everything passes or the file isn't relevant; exit 2 with a short summary
# on stderr when something fails, which Claude Code feeds back to the agent. Reads the hook JSON
# on stdin. POSIX sh; needs python3 (JSON parsing) and luajit or lua.

set -u

root=$(cd "$(dirname "$0")/.." && pwd)
input=$(cat)
file=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
t = d.get("tool_input") or {}
print(t.get("file_path") or t.get("path") or "")' 2>/dev/null)

[ -n "$file" ] || exit 0
case "$file" in
	/*) ;;
	*) file="$root/$file" ;;
esac
case "$file" in
	"$root"/*) ;;
	*) exit 0 ;;
esac

lua=$(command -v luajit || command -v lua || true)
cd "$root" || exit 0
failed=0
report=""

note() {
	report="$report$1
"
	failed=1
}

case "$file" in
	*.lua)
		if [ -n "$lua" ]; then
			out=$("$lua" tests/run.lua --syntax "$file" 2>&1) || note "syntax error: $out"
		fi
		if [ "$failed" -eq 0 ] && command -v luacheck >/dev/null 2>&1; then
			out=$(luacheck --no-color --formatter plain "$file" 2>&1) || note "luacheck:
$out"
		fi
		if [ "$failed" -eq 0 ] && [ -n "$lua" ]; then
			out=$("$lua" tests/run.lua -q unit integration invariants 2>&1) || note "tests failed:
$(printf '%s\n' "$out" | grep -v '^[[:space:]]*\[C\]' | grep -v 'tests/run.lua:' | head -40)"
		fi
		;;
	*.toc | "$root"/.claude/skills/*)
		out=$(python3 tools/check.py 2>&1) || note "tools/check.py:
$out"
		;;
	*)
		exit 0
		;;
esac

if [ "$failed" -ne 0 ]; then
	printf 'TinyTweaks checks failed after editing %s:\n%s' "${file#"$root"/}" "$report" >&2
	exit 2
fi
exit 0
