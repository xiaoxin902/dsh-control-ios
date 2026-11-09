#!/bin/sh
# DSH Control daemon.
#
# launchd starts this script when the app writes
# /var/mobile/Documents/dsh/.dshcontrol-request, runs it as mobile, and it
# exits again. It is the only part that may run the dsh launcher and signal
# the dsh process — the app itself is sandboxed for WebKit's sake.
#
# Only shell builtins, /bin/ps and node22 are used: a launchd job's PATH holds
# none of the bootstrap's tools (no sed, no cat, no date).
set -u
DIR=/var/mobile/Documents/dsh
REQ="$DIR/.dshcontrol-request"
RES="$DIR/.dshcontrol-result"
SCAN=/tmp/.dshcontrol-ps
NODE=/var/jb/usr/local/bin/node22

# One HTTP request: the harness prints its token URL into the log only after
# the first HTTP connection, and the launcher waits for that very line.
POKE='require("http").get("http://127.0.0.1:3080/",function(r){r.resume();r.on("end",function(){process.exit(0)})}).on("error",function(){process.exit(1)})'

[ -f "$REQ" ] || exit 0

CMD=""
while IFS= read -r LINE || [ -n "$LINE" ]; do
	case "$LINE" in
	*'"command"'*)
		REST=${LINE#*\"command\"}
		REST=${REST#*\"}
		CMD=${REST%%\"*}
		;;
	esac
done <"$REQ"

PID=""
if [ -f "$DIR/dsh-web.pid" ]; then
	read -r PID <"$DIR/dsh-web.pid" || true
fi

# Every process running the harness, whatever dsh-web.pid says: the pid file
# goes stale (a killed instance leaves its number behind, and the launcher
# then reports a pid that is not the one serving the port).
# Fills $PIDS with a space separated pid list, spaces around it.
harness_pids() {
	PIDS=""
	if /bin/ps -A -o pid=,command= >"$SCAN" 2>/dev/null; then
		while IFS= read -r LINE; do
			LINE=${LINE#"${LINE%%[! ]*}"}
			P=${LINE%% *}
			C=${LINE#* }
			case "$C" in
			node22* | */node22\ *) ;;
			*) continue ;;
			esac
			case "$C" in
			*"@deepseek-ai/dsh/"*"bin.js"*) PIDS="$PIDS $P" ;;
			esac
		done <"$SCAN"
		rm -f "$SCAN"
	fi
}

OK=false
MSG=unknown-command
TRACE=/tmp/dsh-daemon.log
trace() {
	printf '%s\n' "$*" >>"$TRACE" 2>/dev/null
}

case "$CMD" in
start)
	harness_pids
	FIRST=${PIDS# }
	FIRST=${FIRST%% *}
	if [ -n "$FIRST" ] && kill -0 "$FIRST" 2>/dev/null; then
		OK=true
		MSG=already-running
	else
		# Answer first: the rest takes a few seconds.
		printf '{"ok":true,"message":"starting","command":"start"}\n' >"$RES"
		trace "start: launching"
		"$DIR/dsh" >/dev/null 2>&1 &
		LPID=$!
		# Wait for the harness process to appear (the launcher detaches it).
		I=0
		while [ $I -lt 15 ]; do
			sleep 1
			harness_pids
			[ -n "$PIDS" ] && break
			I=$((I + 1))
		done
		trace "start: after ${I}s harness pids=[$PIDS] launcher=$LPID node=$([ -x "$NODE" ] && echo yes || echo no)"
		if [ -n "$PIDS" ] && [ -x "$NODE" ]; then
			# Retry: the harness prints its URL only after the first HTTP
			# request, and it may not be listening yet.
			I=0
			while [ $I -lt 12 ]; do
				if "$NODE" --jitless -e "$POKE" >/dev/null 2>&1; then
					trace "start: poke ok after ${I}s"
					break
				fi
				sleep 1
				I=$((I + 1))
			done
			trace "start: poke loop ended at ${I}s"
		fi
		# Let the launcher finish by itself: launchd reaps what is left of a
		# job when its main process exits, and the harness must outlive it.
		I=0
		while [ $I -lt 20 ]; do
			kill -0 "$LPID" 2>/dev/null || break
			sleep 1
			I=$((I + 1))
		done
		harness_pids
		if [ -n "$PIDS" ]; then
			OK=true
			MSG=started
		else
			OK=false
			MSG=start-failed
		fi
	fi
	;;
stop)
	# Only pids the scan saw running the harness: a number left in
	# dsh-web.pid may already belong to some other process.
	KILLED=""
	harness_pids
	KILLED="$PIDS"
	if [ -n "$KILLED" ]; then
		for P in $KILLED; do
			kill "$P" 2>/dev/null
		done
		OK=true
		I=0
		while [ $I -lt 10 ]; do
			harness_pids
			[ -z "$PIDS" ] && break
			sleep 1
			I=$((I + 1))
		done
		# A killed process lingers as a zombie until launchd reaps it, so ask
		# the scan (a real command line) rather than kill -0.
		if [ -n "$PIDS" ]; then
			OK=false
		fi
		MSG=stopped
		if [ "$OK" = true ]; then
			rm -f "$DIR/dsh-web.pid"
		else
			MSG=kill-failed
		fi
	else
		MSG=not-running
	fi
	;;
export)
	SCRIPT=/var/jb/usr/libexec/dsh-session-export.js
	[ -f "$SCRIPT" ] || SCRIPT=/var/mobile/.dsh/bin/dsh-session-export.js
	if [ -f "$SCRIPT" ]; then
		HOME=/var/mobile TMPDIR=/tmp PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/usr/bin:/bin \
			"$NODE" --jitless "$SCRIPT" >>/tmp/dsh-daemon.log 2>&1
		RC=$?
	else
		RC=127
	fi
	if [ "$RC" = 0 ] && [ -s /var/mobile/Documents/dsh-backup/exports/latest.md ]; then
		OK=true
		MSG=exported
	else
		OK=false
		MSG=export-failed
		trace "export rc=$RC script=$SCRIPT"
	fi
	;;
esac

printf '{"ok":%s,"message":"%s","command":"%s"}\n' "$OK" "$MSG" "$CMD" >"$RES"

exit 0
