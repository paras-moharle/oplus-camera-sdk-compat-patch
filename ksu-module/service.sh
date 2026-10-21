#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch - late start watcher  (author: Paras Moharle)
#
# The camera app runs in its OWN mount namespace, in which /product/framework
# is an OverlayFS mount that already contains com.oplus.camera.unit.sdk.jar.
# The boot-time bind mount (post-fs-data.sh) is applied in the init namespace
# and is therefore invisible to the camera app, which keeps loading the stock
# jar and keeps failing with
#
#   java.lang.ClassCastException: long[] cannot be cast to int[]
#
# This watcher mounts the patched jar into the camera app's namespace as soon
# as the app appears (measured ~250 ms, before the capture classes are used).
# That is what makes the fix reliable instead of "works in some boots".
#
# It also re-applies the boot-time mount if it is missing for any reason.
#
# Nothing here can fail the boot: every path exits 0.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar
EXPECT=4946460

[ -f "$SRC" ] || exit 0
SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
[ "$SZ" = "$EXPECT" ] || exit 0

# make sure the boot-time mount is there too (init / zygote namespaces)
if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
  mount --bind "$SRC" "$TGT" 2>/dev/null
fi

LAST_PID=""
while true; do
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  if [ -n "$PID" ] && [ "$PID" != "$LAST_PID" ]; then
    # the app may have created its namespace already - mount into it
    nsenter -t "$PID" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
    LAST_PID="$PID"
  fi
  sleep 0.2
done

exit 0
