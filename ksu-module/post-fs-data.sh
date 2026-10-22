#!/system/bin/sh
#
# Oplus camera fix - post-fs-data  (author: Paras Moharle)
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
# WHY THE SDK JAR IS NOT MOUNTED ANY MORE  (read this before editing!)
# -------------------------------------------------------------------
# A bind mount over /product/framework/... does NOT reach the camera app:
#
#   * every app process gets a FRESH mount namespace, and everything this
#     module mounted is removed from it (KernelSU's kmount feature and the
#     Zygisk denamespace both do that).  The app then sees the OEM OverlayFS
#     again - the overlay whose lowerdir is a read-only erofs image.
#   * OverlayFS pins the lowerdir dentry when the overlay is created, so a
#     mount over the merged path or over the lowerdir path is never seen by
#     an open() that goes through the overlay.
#
# The only mechanism that survives all of that is a VFS path redirect in the
# kernel.  This device already runs the NoMount metamodule ("nm"), which
# implements exactly that, and it re-injects the redirects of every module at
# boot from the module's partition tree:
#
#     <module>/product/framework/com.oplus.camera.unit.sdk.jar
#         -> /product/framework/com.oplus.camera.unit.sdk.jar
#     <module>/product/framework/oat/arm64/com.oplus.camera.unit.sdk.{odex,vdex}
#         -> the same paths (the files are empty, so ART must extract the dex
#            from the patched jar instead of using the OEM's stock artifacts)
#
# That redirect is namespace independent, so the camera ALWAYS loads the
# patched SDK, no matter what the mount namespace looks like.
#
# oplus-framework.jar is a BOOTCLASSPATH jar: the zygote opens it once at
# boot and keeps it mapped, so the thermal patch is still delivered as a bind
# mount, created here - before the zygote starts.  Unmounting it later fails
# with "Device or resource busy", which is why the bypass itself is switched
# through a system property that the patched class reads on every call.
#
# SAFETY - READ BEFORE EDITING
# ---------------------------
# * No chcon / setfattr / setenforce here: MediaTek's MKP kernel-integrity
#   module hashes the SELinux state and panics the kernel (-> boot loop) when
#   anything SELinux-related changes while the system is booting.  Labels are
#   set ONCE, at install time, by install.sh.
# * One bind mount only, through bind_once(), which never stacks mounts.
# * Every failure path exits 0.  This script can never fail a boot.
# * Nothing outside /data/adb/modules/ocam_camfix and that one bind mount is
#   touched.

PATH=/system/bin:/system/xbin:/vendor/bin:/bin:/sbin:$PATH
export PATH

MODDIR=/data/adb/modules/ocam_camfix

# the patched jar, kept twice on purpose:
#   SDK-PATCHED.jar                  - the source of truth / what install.sh
#                                      and the tools check
#   product/framework/...sdk.jar     - the file NoMount redirects the OEM path
#                                      to, injected by NoMount's metamount.sh
SDK_SRC="$MODDIR/SDK-PATCHED.jar"
SDK_REDIR="$MODDIR/product/framework/com.oplus.camera.unit.sdk.jar"
OAT_REDIR="$MODDIR/product/framework/oat/arm64"

SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
OAT_TGT=/product/framework/oat/arm64
OFW_SRC="$MODDIR/PATCHED-ofw.jar"
OFW_TGT=/system/framework/oplus-framework.jar

PROP=persist.oplus.camera.thermal_bypass
LOG="$MODDIR/status.txt"

say() { log -t ocam_camfix "$*"; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

[ -f "$SDK_SRC" ] || exit 0

# The run-time switch for the thermal bypass.  A persist.* property survives
# a reboot, so the user's choice is kept.
if [ "$(getprop $PROP)" = "" ]; then
  setprop $PROP 1
fi

# ---------------------------------------------------------------- SDK jar
SDK_EXPECT=$(cat "$MODDIR/SDK-PATCHED.jar.size" 2>/dev/null)
[ -n "$SDK_EXPECT" ] || exit 0
SDK_SZ=$(stat -c %s "$SDK_SRC" 2>/dev/null)
[ -n "$SDK_SZ" ] || exit 0
[ "$SDK_SZ" = "$SDK_EXPECT" ] || exit 0

# The redirect target tree ships in the module zip.  It is re-synced from
# SDK-PATCHED.jar only when the size differs, so that an upgrade can never
# leave an old jar behind.  cp over an EXISTING file keeps its SELinux label
# (system_file, set by install.sh) - never delete and recreate it here.
mkdir -p "$OAT_REDIR" 2>/dev/null
if [ ! -f "$SDK_REDIR" ]; then
  cp -f "$SDK_SRC" "$SDK_REDIR" 2>/dev/null
else
  REDIR_SZ=$(stat -c %s "$SDK_REDIR" 2>/dev/null)
  [ "$REDIR_SZ" = "$SDK_SZ" ] || cp -f "$SDK_SRC" "$SDK_REDIR" 2>/dev/null
fi
for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
  [ -f "$OAT_REDIR/$f" ] || : > "$OAT_REDIR/$f" 2>/dev/null
done

# ------------------------------------------------------------------- rules
#
# NoMount's metamount.sh has normally injected these already (it runs before
# this script).  Adding them here again is cheap and idempotent - "nm rule
# add" REPLACES an existing rule with the same virtual path - and it covers
# the case where the metamodule was updated/reloaded in between.
#
# The parent directory has to be resolved in a namespace where
# /product/framework is the OEM overlay (it is, here: this module mounts
# nothing over /product/framework any more).
NM=""
for c in "$MODDIR/../nomount/bin/nm" /data/adb/ksu/bin/nm /data/adb/ap/bin/nm nm; do
  if command -v "$c" >/dev/null 2>&1; then NM="$c"; break; fi
done

add_rules() {
  [ -n "$NM" ] || return 1
  "$NM" rule add "$SDK_TGT" "$SDK_REDIR" >/dev/null 2>&1 || return 1
  for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
    "$NM" rule add "$OAT_TGT/$f" "$OAT_REDIR/$f" >/dev/null 2>&1 || return 1
  done
  return 0
}

# When is the redirect in effect?  When a plain stat of the OEM path reports
# OUR jar and an empty vdex.  That is the same test service.sh uses.
redirect_ok() {
  SZ=$(stat -Lc %s "$SDK_TGT" 2>/dev/null)
  VZ=$(stat -Lc %s "$OAT_TGT/com.oplus.camera.unit.sdk.vdex" 2>/dev/null)
  [ "$SZ" = "$SDK_SZ" ] && [ "$VZ" = "0" ]
}

# NoMount may still be loading (it is a metamodule, but be defensive).  A few
# one-second retries are enough; boot is never held up for long.
i=0
while [ "$i" -lt 5 ]; do
  add_rules && break
  i=$((i + 1))
  sleep 1
done

if [ -z "$NM" ]; then
  say "WARNING: NoMount (nm) not found - the SDK redirect cannot be applied"
elif redirect_ok; then
  say "SDK redirect active: $(stat -Lc %s "$SDK_TGT") bytes"
else
  say "WARNING: SDK redirect not effective after post-fs-data"
fi

# ART keeps the dexopt output of the jar in /data/dalvik-cache.  If that
# cache was built from the STOCK jar it would keep being used and the camera
# would silently run the unpatched SDK.  It is dropped here, before the
# zygote starts, so that ART always builds it from the jar that is redirected
# now - ours.
DEX_CACHE=/data/dalvik-cache/arm64/product@framework@com.oplus.camera.unit.sdk.jar
rm -f "$DEX_CACHE"@classes.vdex 2>/dev/null
rm -f "$DEX_CACHE"@classes.dex 2>/dev/null

# Legacy leftovers of module versions <= 2.4 (they mounted a replacement
# directory over /product/framework).  The redirect above supersedes them;
# removing the 12 MB copy keeps upgrades clean.  The dir is removed only when
# it is not a live mount source (it still is, in the boot that upgrades from
# v2.x - deleting it then would pull the files out from under the mount).
if [ -d "$MODDIR/pf" ] && ! grep -q "$MODDIR/pf" /proc/self/mountinfo 2>/dev/null; then
  rm -rf "$MODDIR/pf" 2>/dev/null
fi
if [ -f "$MODDIR/empty.bin" ] && ! grep -q "$MODDIR/empty.bin" /proc/self/mountinfo 2>/dev/null; then
  rm -f "$MODDIR/empty.bin" 2>/dev/null
fi

# ----------------------------------------------------------- framework jar
OFW_EXPECT=$(cat "$MODDIR/PATCHED-ofw.jar.size" 2>/dev/null)
[ -n "$OFW_EXPECT" ] || exit 0
OFW_SZ=$(stat -c %s "$OFW_SRC" 2>/dev/null)
[ -n "$OFW_SZ" ] || exit 0
[ "$OFW_SZ" = "$OFW_EXPECT" ] || exit 0

# bind_once <source> <target>
#
# NEVER stack a mount: a mount on an already-mounted path creates another
# mount on top of it, and a loop doing that filled the mount table with 6146
# entries once and took the phone down.  Compare the device+inode instead of
# just the path (/system/framework/oplus-framework.jar is not a mount, but
# /product/framework was, so the inode check is the only safe one).
MOUNTS_MADE=0
MOUNT_CAP=4

already_ours() {
  A=$(stat -Lc "%d:%i" "$1" 2>/dev/null)
  B=$(stat -Lc "%d:%i" "$2" 2>/dev/null)
  [ -n "$A" ] && [ -n "$B" ] && [ "$A" = "$B" ]
}

bind_once() {
  [ -e "$2" ] || return 0
  already_ours "$1" "$2" && return 0
  [ "$MOUNTS_MADE" -ge "$MOUNT_CAP" ] && return 0
  if mount --bind "$1" "$2" 2>/dev/null; then
    MOUNTS_MADE=$((MOUNTS_MADE + 1))
    return 0
  fi
  return 1
}

bind_once "$OFW_SRC" "$OFW_TGT" && say "thermal patch mounted over $OFW_TGT"

exit 0
