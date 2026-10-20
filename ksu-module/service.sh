#!/system/bin/sh
#
# Late-start safety net for the Oplus CameraUnit SDK compat patch.
#
# post-fs-data.sh already tries to bind-mount the patched SDK.  This runs later
# (late-start) and re-applies it in case:
#   * the early mount did not happen yet (e.g. /product was not ready), or
#   * something unmounted it.
#
# Like post-fs-data.sh this is mount-only and can never fail a boot.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar
EXPECT=4946460

[ -f "$SRC" ] || exit 0
SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
[ "$SZ" = "$EXPECT" ] || exit 0

if mount | grep -q " on $TGT "; then
  exit 0
fi

mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
