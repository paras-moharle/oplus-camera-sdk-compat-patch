#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch - late start watcher  (author: Paras Moharle)
#
# WHY THIS EXISTS
# ---------------
# The patched jar only takes effect if it is mounted into the ZYGOTE's mount
# namespace before the camera app is forked from it (ART extracts classes.dex
# from the jar when the app process starts - a mount that appears later is
# never seen).
#
# post-fs-data.sh normally wins that race: it runs at ~t=10 s and the zygote
# starts at ~t=12-13 s.  On a loaded phone (this one runs a MediaTek MKP
# kernel-panic storm, load average 20+) the zygote sometimes starts first and
# the race is lost - the camera then silently keeps using the stock jar and
# every photo is cancelled with CF_APS_FINISH_ADD_FRAME.
#
# This watcher closes the race from the other side: as soon as the zygote is
# running it mounts the patched jar into the zygote's namespace.  Every app
# forked from that point on inherits the mount.
#
# It also re-applies the mount into the camera app's own namespace.  That is
# only useful for code that opens the jar *after* the app has started (the
# dex is already extracted by then), but it costs nothing and keeps the file
# consistent for the app.
#
# SAFETY
# ------
# * Only "mount --bind" is used.  No chcon / setfattr / setenforce: the MKP
#   kernel-integrity module panics the kernel if the SELinux state changes
#   while the system boots.
# * Every failure path exits 0.  This script can never fail a boot.
# * It never restarts or kills any app.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

[ -f "$SRC" ] || exit 0

EXPECT=$(cat "$MODDIR/SDK-PATCHED.jar.size" 2>/dev/null)
[ -n "$EXPECT" ] || exit 0

SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
[ "$SZ" = "$EXPECT" ] || exit 0

LAST_Z=""
LAST_PID=""
SPIN_TICKS=0
SPIN_SAMPLES=0

# The camera's private-log writer (persist.sys.camera.private.log.enable) can
# end up in a tight retry loop if it is not allowed to write /data/vendor.
# That loop pegs a CPU core, floods the log buffer and gets the camera
# process killed.  If the camera burns more than ~10 CPU-seconds per second
# for 20 seconds in a row, something is spinning - turn the private log off
# so the camera survives.  (A normal capture uses well under one CPU-second.)
watchdog_camera_spin() {
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  [ -n "$PID" ] || return 0
  [ -r "/proc/$PID/stat" ] || return 0
  CUR=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null)
  [ -n "$CUR" ] || return 0
  if [ -n "$SPIN_PREV" ]; then
    D=$((CUR - SPIN_PREV))
    if [ "$D" -gt 200 ]; then
      SPIN_TICKS=$((SPIN_TICKS + D))
    else
      SPIN_TICKS=0
    fi
  fi
  SPIN_PREV="$CUR"
  SPIN_SAMPLES=$((SPIN_SAMPLES + 1))
  if [ "$SPIN_SAMPLES" -ge 20 ] && [ "$SPIN_TICKS" -gt 2000 ]; then
    setprop persist.sys.camera.private.log.enable false
    SPIN_TICKS=0
    SPIN_SAMPLES=0
  fi
}

while true; do
  # --- the zygote: the important one -------------------------------------
  Z=""
  for p in $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
    Z="$p"
    break
  done

  if [ -n "$Z" ] && [ "$Z" != "$LAST_Z" ]; then
    LAST_Z="$Z"
    nsenter -t "$Z" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
  fi

  # --- init namespace (in case it was lost) ------------------------------
  if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
    mount --bind "$SRC" "$TGT" 2>/dev/null
  fi

  # --- the camera app's own namespace (cosmetic, see header) -------------
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  if [ -n "$PID" ] && [ "$PID" != "$LAST_PID" ]; then
    nsenter -t "$PID" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
    LAST_PID="$PID"
  fi

  sleep 0.5

  watchdog_camera_spin
done

exit 0
