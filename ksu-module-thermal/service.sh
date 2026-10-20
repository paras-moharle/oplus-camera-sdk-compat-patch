#!/system/bin/sh
#
# Late-start safety net for the camera thermal bypass.
#
# post-fs-data.sh already bind-mounts the patched framework jar, and it must
# run BEFORE the zygote starts (~6 s vs ~12 s) because the zygote opens the
# bootclasspath at startup.  This script only re-applies the mount if it is
# missing for some reason - e.g. if the early mount did not happen.
#
# Same guards, same rules: mount only, never exits non-zero.

MODDIR=/data/adb/modules/ocam_thermalfix
SRC="$MODDIR/PATCHED-ofw.jar"
REF="$MODDIR/ORIGINAL-ofw.jar"
SIZE_FILE="$MODDIR/PATCHED-ofw.jar.size"
TGT=/system/framework/oplus-framework.jar

[ -f "$SRC" ] || exit 0

if awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
  exit 0
fi

SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
if [ -f "$SIZE_FILE" ]; then
  EXPECT=$(cat "$SIZE_FILE" 2>/dev/null)
  [ -n "$EXPECT" ] || exit 0
  [ "$SZ" = "$EXPECT" ] || exit 0
fi

[ -f "$REF" ] || exit 0
A=$(sha256sum "$TGT" 2>/dev/null | cut -d' ' -f1)
B=$(sha256sum "$REF" 2>/dev/null | cut -d' ' -f1)
[ -n "$A" ] || exit 0
[ -n "$B" ] || exit 0
[ "$A" = "$B" ] || exit 0

mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
