#!/bin/sh
# Reads what an in-game test session left on disk (see tools/ingame_report.lua).
#
#   tools/ingame.sh report        print the report for the last session
#   tools/ingame.sh wait [hours]  block until the game logs out, then print the report for every
#                                 session since the wait began; gives up after [hours] (default 4)
#
# With SAVES=n the wait also ends after n saves: each /reload and each logout writes the
# SavedVariables once, so a test script with two /reloads that ends with a third passes SAVES=3.
# Without SAVES only a logout ends it, however many /reloads come first.
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

# $1: report sessions that ended since this time ("YYYY-MM-DD HH:MM:SS"); default: the last one.
report() {
	dir=$(sv_dir)
	"$LUA" "$HERE/ingame_report.lua" "$dir/TinyTweaks.lua" "$dir/!TinyTweaksDev.lua" "$WOW_DIR/Logs/taint.log" ${1:+"$1"}
}

wait_for_logout() {
	dev="$(sv_dir)/!TinyTweaksDev.lua"
	deadline=$(( $(date +%s) + ${1:-4} * 3600 ))
	since=$(date '+%Y-%m-%d %H:%M:%S')
	last=$(mtime "$dev")
	saves=0
	if [ -n "${SAVES:-}" ]; then
		echo "waiting for $SAVES saves (/reload or logout) or a logout (watching $dev)"
	else
		echo "waiting for the game to log out (watching $dev)"
	fi
	while [ "$(date +%s)" -lt "$deadline" ]; do
		sleep 3
		now=$(mtime "$dev")
		if [ "$now" != "$last" ]; then
			last=$now
			saves=$((saves + 1))
			sleep 2 # let the client finish writing
			ended=$("$LUA" "$HERE/ingame_report.lua" --ended "$dev")
			if [ "$ended" = "logout" ] || { [ -n "${SAVES:-}" ] && [ "$saves" -ge "$SAVES" ]; }; then
				report "$since"
				return 0
			fi
			echo "saved variables written ($ended, save $saves${SAVES:+ of $SAVES}); still waiting"
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
