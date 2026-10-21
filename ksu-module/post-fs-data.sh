#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch  (author: Paras Moharle)
#
# WHY
# ---
# The Oplus CameraUnit SDK (com.oplus.camera.unit.sdk.jar) that ships with
# 6.020.980-era firmware drives the still capture.  Three things in it have
# to be corrected for the camera to work on this device:
#
#  1. BaseMode.updateCaptureRequestTag() reads the capture parameter
#     "com.oplus.picture.exif.flag" with a hard (int[]) cast.  Newer camera
#     apps store it as a long[] -> java.lang.ClassCastException, the capture
#     request is never built and the shot is cancelled.
#
#  2. ProducerImpl.takePicture() refuses every capture while the AI/APS
#     stack has not finished ("mbApsFinishAddFrame"), which it never does on
#     this firmware because /odm/lib64 is missing
#     libai_perception_scene_detect.so, libarcsoft_hdr_denoise_api_v4.so,
#     libImplicitWatermark.so, libUpScale.so and the com.oplus.aps.params.*
#     config.
#
#  3. BaseMode.isNeedAPSProcess() is hard-coded to true, so the camera always
#     enters the broken APS branch.  It has to return false so the plain
#     (no-AI) capture path is used.
#
# All three patches are in one patched copy of the jar.  The original file on
# disk is NOT modified - the patched copy is bind-mounted over it.
#
# THE MOUNT NAMESPACE (the part that is easy to get wrong)
# ------------------------------------------------------
# The camera app does not run in the mount namespace of init:
#
#   * init creates /product/framework as an OverlayFS whose lowerdir is
#     /mnt/vendor/my_product/product_overlay/framework/
#   * the zygote unshares its own mount namespace and makes the root mount a
#     slave, so every mount that init performs AFTER the zygote has started
#     is invisible to the zygote and to every app forked from it
#   * ART extracts classes.dex from the jar when the app process starts, so
#     mounting the patched jar into the app's namespace afterwards is USELESS
#     - the app has already loaded the stock classes
#
# So the patched jar has to be mounted into the ZYGOTE's mount namespace
# before the camera app is forked from it.  That is what this script does
# (and what service.sh retries if the zygote was not up yet).
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

[ -f "$SRC" ] || exit 0

# expected size of the patched jar - guards against a truncated/partial file
EXPECT=$(cat "$MODDIR/SDK-PATCHED.jar.size" 2>/dev/null)
[ -n "$EXPECT" ] || exit 0

SZ=$(stat -c %s "$SRC" 2>/dev/null)
[ -n "$SZ" ] || exit 0
[ "$SZ" = "$EXPECT" ] || exit 0

# 1) the init namespace - makes the patched jar visible to everything that
#    is started from here on (including the zygote, if it is not up yet)
if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
  mount --bind "$SRC" "$TGT" 2>/dev/null
fi

# 2) the zygote namespace - this is the one that matters.  The zygote forks
#    every app, so a mount that is visible to the zygote is inherited by all
#    apps started afterwards, and ART then extracts the PATCHED classes.dex.
Z=""
for p in $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
  Z="$p"
  break
done

if [ -n "$Z" ]; then
  nsenter -t "$Z" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
fi

exit 0
