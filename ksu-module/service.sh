#!/system/bin/sh
#
# Late-start safety net for the Oplus CameraUnit SDK compat patch.
#
# post-fs-data.sh already tries to bind-mount the patched SDK.  This runs later
# (late-start) and re-applies it in case:
#   * the early mount did not happen yet (e.g. /product was not ready), or
#   * something unmounted it.
#
# Like post-fs-data.sh this is mount-only, has the same guards, and can never
# fail a boot.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
REF="$MODDIR/SDK-ORIGINAL.jar"
SIZE_FILE="$MODDIR/SDK-PATCHED.jar.size"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

[ -f "$SRC" ] || exit 0

# already mounted?  then there is nothing to do
if awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
  exit 0
fi

# --- guard 1: the patched jar must be a complete file --------------------
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

# --- guard 2: the SDK on disk must be the one this jar was built from ----
[ -f "$REF" ] || exit 0
A=$(sha256sum "$TGT" 2>/dev/null | cut -d' ' -f1)
B=$(sha256sum "$REF" 2>/dev/null | cut -d' ' -f1)
[ -n "$A" ] || exit 0
[ -n "$B" ] || exit 0
if [ "$A" != "$B" ]; then
  log -t ocam_sdkfix "SDK on disk does not match this module (OTA or different firmware) - not mounting" 2>/dev/null || true
  exit 0
fi

# --- mount ---------------------------------------------------------------
mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
