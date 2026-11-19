#!/bin/sh
# Reads what an in-game test session left on disk (see tools/ingame_report.lua).
#
#   tools/ingame.sh report        print the report for the last session
#   tools/ingame.sh wait [hours]  block until the game logs out (not a /reload), then print the
#                                 report; gives up after [hours] (default 4)
#
# WOW_DIR defaults to the WoW Forever install. The account folder is the one whose TinyTweaks
# SavedVariables changed most recently.
set -eu

WOW_DIR=${WOW_DIR:-"/Applications/World of Warcraft/_forever_"}
LUA=${LUA:-luajit}
HERE=$(cd "$(dirname "$0")" && pwd)

sv_dir() {
	newest=$(ls -t "$WOW_DIR"/WTF/Account/*/SavedVariables/TinyTweaks.lua 2>/dev/null | head -n 1)
	if [ -z "$newest" ]; then
		echo "error: no TinyTweaks SavedVariables under $WOW_DIR/WTF/Account (log in once with TinyTweaks enabled)" >&2
		exit 1
	fi
	dirname "$newest"
}

mtime() {
	stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

report() {
	dir=$(sv_dir)
	"$LUA" "$HERE/ingame_report.lua" "$dir/TinyTweaks.lua" "$dir/!TinyTweaksDev.lua" "$WOW_DIR/Logs/taint.log"
}

wait_for_logout() {
	dev="$(sv_dir)/!TinyTweaksDev.lua"
	deadline=$(( $(date +%s) + ${1:-4} * 3600 ))
	last=$(mtime "$dev")
	echo "waiting for the game to log out (watching $dev)"
	while [ "$(date +%s)" -lt "$deadline" ]; do
		sleep 3
		now=$(mtime "$dev")
		if [ "$now" != "$last" ]; then
			last=$now
			sleep 2 # let the client finish writing
			ended=$("$LUA" "$HERE/ingame_report.lua" --ended "$dev")
			if [ "$ended" = "logout" ]; then
				report
				return 0
			fi
			echo "saved variables written ($ended); still waiting for a logout"
		fi
	done
	echo "gave up waiting after ${1:-4} hours" >&2
	return 1
}

case "${1:-}" in
report) report ;;
wait) wait_for_logout "${2:-4}" ;;
*)
	echo "usage: tools/ingame.sh report | wait [hours]" >&2
	exit 2
	;;
esac
