#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch  (author: Paras Moharle)
#
# WHY
# ---
# Camera 6.070.215+ stores the "com.oplus.picture.exif.flag" capture parameter
# as a long[], while the CameraUnit SDK shipped with 6.020.980-era firmware
# reads it back with a hard (int[]) cast:
#
#   java.lang.ClassCastException: long[] cannot be cast to int[]
#     at com.oplus.ocs.camera.producer.mode.BaseMode.updateCaptureRequestTag(BaseMode.java:1957)
#     at com.oplus.ocs.camera.producer.ProducerImpl.takePicture(ProducerImpl.java:849)
#
# The still-capture request is therefore never built, the capture is cancelled
# and no photo is written.  Video is unaffected.
#
# WHAT
# ---
# This bind-mounts a patched copy of the SDK over the original.  The original
# file on disk is NOT modified, so removing the module restores stock exactly.
#
# SAFETY - READ BEFORE EDITING
# ---------------------------
# * This script performs a "mount --bind" and NOTHING else.  It must never run
#   chcon / setfattr / setenforce: MediaTek's MKP kernel-integrity module hashes
#   the SELinux state and panics the kernel (-> kernel panic, boot loop) when
#   anything SELinux-related changes while the system is booting.
#   The SELinux label of the jar is therefore set ONCE, at install time, by
#   install.sh - never from a boot-time script.
# * Three guards decide whether the mount happens at all:
#     1. the patched jar must be complete (recorded size, or zip magic),
#     2. the SDK on disk must be byte-identical to the SDK this patched jar
#        was built from  ->  the module cannot shadow a different firmware,
#     3. nothing else on the device is touched.
# * Every failure path exits 0.  This script can never fail a boot.

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
# Without this the release zip (which carries a jar built on one specific
# device) could be flashed onto a device with different firmware and would
# silently replace that device's SDK with an incompatible one.  After an OTA
# the SDK changes, this guard trips, and the module steps aside on its own.
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
