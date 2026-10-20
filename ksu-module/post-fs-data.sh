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
# * Every failure path exits 0.  This script can never fail a boot.
# * Nothing outside /data/adb/modules/ocam_sdkfix and the single bind mount
#   is touched.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

# expected size of the patched jar - guards against a truncated/partial file
EXPECT=4946460

[ -f "$SRC" ] || exit 0

# make sure the source is a complete file and carries a readable label
SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
[ "$SZ" = "$EXPECT" ] || exit 0

# already mounted?  then nothing to do
if mount | grep -q " on $TGT "; then
  exit 0
fi

mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
