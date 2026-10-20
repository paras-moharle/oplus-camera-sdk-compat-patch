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
SIZE_FILE="$MODDIR/SDK-PATCHED.jar.size"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

[ -f "$SRC" ] || exit 0
SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
if [ -f "$SIZE_FILE" ]; then
  EXPECT=$(cat "$SIZE_FILE" 2>/dev/null)
  [ -n "$EXPECT" ] || exit 0
  [ "$SZ" = "$EXPECT" ] || exit 0
else
  [ "$SZ" -ge 1000000 ] || exit 0
  case "$(head -c 2 "$SRC" 2>/dev/null)" in
    PK) ;;
    *) exit 0 ;;
  esac
fi

if mount | grep -q " on $TGT "; then
  exit 0
fi

mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
