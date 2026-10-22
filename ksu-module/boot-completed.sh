#!/system/bin/sh
#
# Oplus camera fix - boot-completed  (author: Paras Moharle)
#
# The watcher in service.sh is an ordinary process: an OOM kill, a `killall`,
# or a module reload can take it down.  KernelSU only starts service.sh once
# per boot, so nothing would notice.  This script runs at boot_completed (the
# last boot stage) and makes sure the watcher is alive; if it is not, it is
# started again.
#
# It also does one final, user-visible verification of the SDK redirect, so a
# broken boot is reported instead of silently cancelling every capture.
#
# SAFETY
# ------
# * No chcon / setfattr / setenforce, no mounts, no app restart here.
# * Every failure path exits 0.

PATH=/system/bin:/system/xbin:/vendor/bin:/bin:/sbin:$PATH
export PATH

MODDIR=/data/adb/modules/ocam_camfix
SDK_SRC="$MODDIR/SDK-PATCHED.jar"
SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
OAT_TGT=/product/framework/oat/arm64
LOG="$MODDIR/status.txt"

[ -f "$SDK_SRC" ] || exit 0

record() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

SDK_SZ=$(stat -c %s "$SDK_SRC" 2>/dev/null)
[ -n "$SDK_SZ" ] || exit 0

# 1) keep the watcher alive (its own pidfile; no pattern matching, which would
#    also match the shell that runs the check)
WATCH_PID=$(cat "$MODDIR/service.pid" 2>/dev/null)
if [ -n "$WATCH_PID" ] && [ -r "/proc/$WATCH_PID/cmdline" ] &&
   tr '\0' ' ' < "/proc/$WATCH_PID/cmdline" 2>/dev/null | grep -q "ocam_camfix/service.sh"; then
  record "boot-completed: watcher is running (pid $WATCH_PID)"
else
  record "boot-completed: watcher was not running - starting it"
  setsid sh "$MODDIR/service.sh" >/dev/null 2>&1 < /dev/null &
fi

# 2) verify the redirect, once, and tell the user if the camera would be broken
SZ=$(stat -Lc %s "$SDK_TGT" 2>/dev/null)
VZ=$(stat -Lc %s "$OAT_TGT/com.oplus.camera.unit.sdk.vdex" 2>/dev/null)

if [ "$SZ" = "$SDK_SZ" ] && [ "$VZ" = "0" ]; then
  record "boot-completed: SDK redirect verified ($SZ bytes, prebuilt vdex masked)"
  exit 0
fi

record "boot-completed: SDK redirect NOT effective (size=${SZ:-?} want=$SDK_SZ vdex=${VZ:-?})"
cmd notification post "Oplus camera fix" "Camera fix is NOT active: the patched SDK is not being loaded. Open the module status.txt for details." >/dev/null 2>&1 || true
exit 0
