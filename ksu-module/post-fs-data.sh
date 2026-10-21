#!/system/bin/sh
#
# Oplus camera fix - CameraUnit SDK + thermal bypass  (author: Paras Moharle)
#
# WHAT THIS MODULE DOES
# ---------------------
# Two independent fixes, one module:
#
#  1. CameraUnit SDK (com.oplus.camera.unit.sdk.jar, /product/framework)
#     - BaseMode.updateCaptureRequestTag() accepts long[] as well as int[]
#     - BaseMode.isNeedAPSProcess() returns false  (the AI/APS stack cannot run
#       on this firmware, so the camera must not use it)
#     - ProducerImpl.takePicture() can no longer cancel a capture because the
#       APS did not finish
#     Without this the camera takes NO photo at all - not even with the stock
#     6.020.980 app.
#
#  2. Thermal bypass (oplus-framework.jar, /system/framework)
#     The camera app defers every capture while the skin temperature is above
#     the hard-coded 41 degC limit.  The patched
#     com/oplus/util/OplusHoraeThermalHelper reports 30 degC / status 13 to the
#     camera process only.  Every other app keeps the real values.
#
#     The bypass can be switched OFF at run time with a volume key - see
#     service.sh.  It is controlled by the system property
#
#         persist.oplus.camera.thermal_bypass   (1 = on, 0 = off)
#
# THE MOUNT NAMESPACE (the part that is easy to get wrong)
# ------------------------------------------------------
# The camera app does not run in the mount namespace of init:
#
#   * the zygote unshares its own mount namespace and makes the root mount a
#     slave, so every mount that init performs AFTER the zygote has started is
#     invisible to the zygote and to every app forked from it
#   * ART extracts classes.dex from the jar when the app process starts, so
#     mounting the patched jar into the app's namespace afterwards is USELESS
#     - the app has already loaded the stock classes
#
# So the patched SDK jar has to be mounted into the ZYGOTE's mount namespace
# before the camera app is forked from it.  That is what this script does
# (and what service.sh retries if the zygote was not up yet).
#
# oplus-framework.jar is a BOOTCLASSPATH jar: the zygote opens it once at
# boot and keeps it mapped, so the mount over it can only be created at boot
# time (unmounting it later fails with "Device or resource busy").  That is
# why the thermal bypass is switched through a system property that the
# patched class reads on every call, instead of by re-mounting the jar.
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
# * Nothing outside /data/adb/modules/ocam_camfix and the two bind mounts is
#   touched.

MODDIR=/data/adb/modules/ocam_camfix

SDK_SRC="$MODDIR/SDK-PATCHED.jar"
SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
OFW_SRC="$MODDIR/PATCHED-ofw.jar"
OFW_TGT=/system/framework/oplus-framework.jar

[ -f "$SDK_SRC" ] || exit 0
[ -f "$OFW_SRC" ] || exit 0

# The run-time switch for the thermal bypass.  A persist.* property survives
# a reboot, so the user's choice is kept.
if [ "$(getprop persist.oplus.camera.thermal_bypass)" = "" ]; then
  setprop persist.oplus.camera.thermal_bypass 1
fi

# ---------------------------------------------------------------- SDK jar
SDK_EXPECT=$(cat "$MODDIR/SDK-PATCHED.jar.size" 2>/dev/null)
[ -n "$SDK_EXPECT" ] || exit 0
SDK_SZ=$(stat -c %s "$SDK_SRC" 2>/dev/null)
[ -n "$SDK_SZ" ] || exit 0
[ "$SDK_SZ" = "$SDK_EXPECT" ] || exit 0

# 1) the init namespace
if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$SDK_TGT"; then
  mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
fi

# ART keeps the dexopt output of the jar in /data/dalvik-cache.  If that
# cache was built from the STOCK jar it would keep being used and the camera
# would silently run the unpatched SDK.  It is dropped here, before the
# zygote starts, so that ART always builds it from the jar that is mounted
# now - ours.
DEX_CACHE=/data/dalvik-cache/arm64/product@framework@com.oplus.camera.unit.sdk.jar
rm -f "$DEX_CACHE"@classes.vdex 2>/dev/null
rm -f "$DEX_CACHE"@classes.dex 2>/dev/null

# 2) the zygote namespace - this is the one that matters.
#
# ART opens the jar itself (it is not a bootclasspath jar) and, when it opens
# the STOCK jar, it matches the OEM's prebuilt artifact
#
#     /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex
#
# which was compiled from the stock code - so the camera silently runs the
# unpatched SDK and every capture is cancelled.  The mount has to be in place
# BEFORE the app process starts, which means before the zygote forks it.
#
# The prebuilt artifacts are invalidated as well, so ART can never fall back
# to the stock compiled code.
#
# The OEM ships a prebuilt dexopt artifact for the CameraUnit SDK jar:
#
#     /product/framework/oat/arm64/com.oplus.camera.unit.sdk.odex
#     /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex
#
# They were compiled from the STOCK jar.  When ART finds them it uses them
# and never looks at the jar - so even though the patched jar was mounted,
# the camera ran the STOCK sdk and cancelled every capture with no error
# anywhere.  Masking both with an empty file forces ART to extract the dex
# from the jar that is actually mounted (ours).
OAT_DIR=/product/framework/oat/arm64
: > "$MODDIR/empty.bin" 2>/dev/null
for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
  [ -e "$OAT_DIR/$f" ] || continue
  if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$OAT_DIR/$f"; then
    mount --bind "$MODDIR/empty.bin" "$OAT_DIR/$f" 2>/dev/null
  fi
done

Z=""
for p in $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
  Z="$p"
  break
done
if [ -n "$Z" ]; then
  nsenter -t "$Z" -m -- mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
  for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
    [ -e "$OAT_DIR/$f" ] && nsenter -t "$Z" -m -- mount --bind "$MODDIR/empty.bin" "$OAT_DIR/$f" 2>/dev/null
  done
fi

# ----------------------------------------------------------- framework jar
OFW_EXPECT=$(cat "$MODDIR/PATCHED-ofw.jar.size" 2>/dev/null)
[ -n "$OFW_EXPECT" ] || exit 0
OFW_SZ=$(stat -c %s "$OFW_SRC" 2>/dev/null)
[ -n "$OFW_SZ" ] || exit 0
[ "$OFW_SZ" = "$OFW_EXPECT" ] || exit 0

if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$OFW_TGT"; then
  mount --bind "$OFW_SRC" "$OFW_TGT" 2>/dev/null
fi

exit 0
