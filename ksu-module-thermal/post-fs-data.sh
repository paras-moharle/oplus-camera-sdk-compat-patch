#!/system/bin/sh
#
# Oplus camera thermal bypass  (author: Paras Moharle)
#
# WHY
# ---
# Oplus Camera 6.070.215 (and the stock 6.020.980) hard-code the capture
# temperature threshold:
#
#     common_capture_temperature_threshold = "41"   (qc/a2.smali / ka/m1.smali)
#
# and compare it against the skin temperature reported by Oplus' "horae"
# thermal service:
#
#     dumpsys horae  ->  Temp: 41.53
#
# Because the phone idles at 41-44 degC, the camera's capture-defer logic is
# engaged permanently: every capture is deferred (3-6 s), the preview is
# degraded and video recording is refused.  The threshold cannot be changed by
# configuration - the OEM code fills a map keyed by the label string but looks
# it up with the enum object, so the lookup always misses and the hard-coded
# default is always used.
#
# WHAT
# ---
# This bind-mounts a patched /system/framework/oplus-framework.jar over the
# original.  In com.oplus.util.OplusHoraeThermalHelper, getCurrentThermal()
# and getThermalStatus() return a capped value (30 degC / level 0) for the
# camera process only (uid 10155).  Every other process keeps seeing the real
# values, so charging limits, game mode and the thermal governor are
# unaffected.  The original file on disk is NOT modified.
#
# SAFETY - READ BEFORE EDITING
# ---------------------------
# * This script performs a "mount --bind" and NOTHING else.  Never add
#   chcon / setfattr / setenforce here: MediaTek's MKP kernel-integrity module
#   panics the kernel when anything SELinux-related changes while booting.
#   The label is set ONCE, at install time.
# * The jar must carry the same SELinux label as the original
#   (u:object_r:system_file:s0).  The zygote opens the bootclasspath at boot;
#   with the wrong label it cannot read the jar and the phone boot-loops.
# * The mount must be in place BEFORE the zygote starts (post-fs-data, ~6 s;
#   the zygote starts at ~12 s), otherwise the stock jar stays in memory.
# * Every failure path exits 0.  This script can never fail a boot.

MODDIR=/data/adb/modules/ocam_thermalfix
SRC="$MODDIR/PATCHED-ofw.jar"
REF="$MODDIR/ORIGINAL-ofw.jar"
SIZE_FILE="$MODDIR/PATCHED-ofw.jar.size"
TGT=/system/framework/oplus-framework.jar

[ -f "$SRC" ] || exit 0

# already mounted?  then there is nothing to do
if awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$TGT"; then
  exit 0
fi

# the jar must be complete
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

# the framework on disk must be the one this jar was patched from
[ -f "$REF" ] || exit 0
A=$(sha256sum "$TGT" 2>/dev/null | cut -d' ' -f1)
B=$(sha256sum "$REF" 2>/dev/null | cut -d' ' -f1)
[ -n "$A" ] || exit 0
[ -n "$B" ] || exit 0
if [ "$A" != "$B" ]; then
  log -t ocam_thermalfix "framework jar does not match this module (OTA?) - not mounting" 2>/dev/null || true
  exit 0
fi

mount --bind "$SRC" "$TGT" 2>/dev/null

exit 0
