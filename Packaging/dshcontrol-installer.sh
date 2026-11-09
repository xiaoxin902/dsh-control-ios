#!/bin/sh
# dshcontrol-installer — 只做一件事：把 inbox 里的插件包装上。
#
# launchd 以 root 起它（WatchPaths 盯着 inbox 目录），它检查、安装、写结果、
# 把包移到 done/ 或 rejected/，然后退出。它故意不做别的：
#   1. 只认 /var/mobile/Documents/dsh/inbox/*.deb
#   2. 带 maintainer script（preinst/postinst/prerm/postrm）的包一律拒绝
#   3. 除 Library/MobileSubstrate/DynamicLibraries/ 以外的路径一律拒绝
# 由 Apelin 打包时替换 @ROOTFS@（系统路径前缀）与 @PREFIX@（引导区前缀）。
set -u

# launchd 给的 PATH 是空的，mv/basename/mktemp/date 都在引导区里
PATH="@PREFIX@/usr/bin:@PREFIX@/bin:@PREFIX@/usr/sbin:@PREFIX@/sbin:/usr/bin:/bin"
export PATH

DIR=@ROOTFS@/var/mobile/Documents/dsh
INBOX=$DIR/inbox
WORK=$DIR/installer
DONE=$WORK/done
REJECTED=$WORK/rejected
RESULT=$WORK/result.json
LOG=$WORK/installer.log
IRISIN=@PREFIX@/usr/bin/irisin-cli
DPKG=@PREFIX@/usr/bin/dpkg-deb
FIND=@PREFIX@/usr/bin/find
PLUGINDIR=Library/MobileSubstrate/DynamicLibraries

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-')" "$*" >>"$LOG" 2>/dev/null
}

# 把结果写成手机侧可读的 JSON（mobile 501 才能读，root 创建的默认是 0600）
finish() {
	ok="$1"
	msg="$2"
	deb="$3"
	flat=$(printf '%s' "$msg" | tr '\n"' '  ' | cut -c1-500)
	printf '{"ok":%s,"message":"%s","deb":"%s"}\n' "$ok" "$flat" "$deb" >"$RESULT.tmp" 2>/dev/null &&
		mv -f "$RESULT.tmp" "$RESULT" 2>/dev/null
	chmod 0644 "$RESULT" 2>/dev/null
	chown 501:501 "$RESULT" 2>/dev/null
	log "ok=$ok deb=$deb msg=$flat"
}

reject() {
	msg="$1"
	finish false "$msg" "$CURRENT"
	[ -n "${CURRENT:-}" ] && [ -f "$CURRENT" ] && mv -f "$CURRENT" "$REJECTED/" 2>/dev/null
	rm -rf "${XDIR:-}" 2>/dev/null
	CURRENT=""
}

[ -d "$INBOX" ] || exit 0
mkdir -p "$DONE" "$REJECTED" 2>/dev/null || true
set -- "$INBOX"/*.deb
count=0
for f in "$@"; do [ -f "$f" ] && count=$((count + 1)); done
log "run started, candidates=$count"

for deb in "$INBOX"/*.deb; do
	[ -f "$deb" ] || continue

	# 先挪进工作区，避免目录事件再次触发时重复处理
	CURRENT="$WORK/current.deb"
	if ! mv -f "$deb" "$CURRENT" 2>/dev/null; then
		CURRENT=""
		continue
	fi
	log "picked $(basename "$deb")"

	XDIR=$(mktemp -d "$WORK/x.XXXXXX" 2>/dev/null) || {
		reject "cannot create temp dir"
		continue
	}

	# 1) control 区：有 maintainer script 就拒绝
	if ! "$DPKG" -e "$CURRENT" "$XDIR/ctl" >/dev/null 2>&1; then
		reject "not a debian package (dpkg-deb -e failed)"
		continue
	fi
	bad=""
	for s in preinst postinst prerm postrm; do
		[ -f "$XDIR/ctl/$s" ] && bad="$bad $s"
	done
	if [ -n "$bad" ]; then
		reject "refused: package carries maintainer script($bad)"
		continue
	fi

	# 2) 数据区：只允许插件目录下的文件
	if ! "$DPKG" -x "$CURRENT" "$XDIR/root" >/dev/null 2>&1; then
		reject "cannot extract data"
		continue
	fi
	outside=$(cd "$XDIR/root" && "$FIND" . \( -type f -o -type l \) 2>/dev/null | while IFS= read -r p; do case "$p" in "./$PLUGINDIR/"*|"./var/jb/$PLUGINDIR/"*) ;; *) printf '%s\n' "$p" ;; esac; done | head -3)
	if [ -n "$outside" ]; then
		reject "refused: installs outside /$PLUGINDIR ($(printf '%s' "$outside" | tr '\n' ' '))"
		continue
	fi
	dylib=$(cd "$XDIR/root" && { [ -d "./$PLUGINDIR" ] && "$FIND" "./$PLUGINDIR" -type f -name '*.dylib' 2>/dev/null; [ -d "./var/jb/$PLUGINDIR" ] && "$FIND" "./var/jb/$PLUGINDIR" -type f -name '*.dylib' 2>/dev/null; } | head -1)
	if [ -z "$dylib" ]; then
		reject "refused: no .dylib in /$PLUGINDIR"
		continue
	fi
	setuid=$(cd "$XDIR/root" && "$FIND" . -type f -perm -4000 2>/dev/null | head -3)
	if [ -n "$setuid" ]; then
		reject "refused: setuid files"
		continue
	fi

	# 3) 安装
	log "installing $(basename "$CURRENT")"
	out=$(TMPDIR="$WORK" "$IRISIN" install --yes "$CURRENT" 2>&1)
	rc=$?
	if [ $rc -eq 0 ]; then
		finish true "installed" "$CURRENT"
		mv -f "$CURRENT" "$DONE/" 2>/dev/null
	else
		finish false "install failed (exit $rc): $out" "$CURRENT"
		mv -f "$CURRENT" "$REJECTED/" 2>/dev/null
	fi
	rm -rf "${XDIR:-}" 2>/dev/null
	CURRENT=""
done

exit 0
