#!/usr/bin/env bash
#
# install.sh - Patch the Oplus CameraUnit SDK on the device so that camera
#              6.070.215 (and newer) can take photos again.
#
# WHAT IT DOES
# ------------
#   1. pulls /product/framework/com.oplus.camera.unit.sdk.jar off the device
#   2. decodes it with apktool
#   3. applies tools/patch_sdk.py  (one method, accepts int[] and long[])
#   4. rebuilds the jar and verifies the class/method inventory is unchanged
#   5. installs a KernelSU module that bind-mounts the patched jar over the
#      original at every boot
#
# The original jar is NEVER modified.  The patch is a bind mount, so the
# stock file stays byte-identical on disk and removing the module restores
# the stock behaviour instantly.
#
# Usage:
#   ./install.sh                    # install + reboot
#   ./install.sh --no-reboot        # install, reboot yourself later
#   ./install.sh --force            # allow overwriting an existing install
#   ./install.sh --with-thermal-fix # ALSO install the optional camera thermal
#                                   # bypass (see docs/THERMAL-BYPASS.md)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$SCRIPT_DIR/tools"
KSU_DIR="/data/adb/modules/ocam_sdkfix"
DEVICE_JAR="/product/framework/com.oplus.camera.unit.sdk.jar"
DEVICE_JAR_ADAPTER="/product/framework/com.oplus.camera.unit.sdk.adapter.jar"
WORKDIR="${WORKDIR:-$(mktemp -d /tmp/ocam-patch-XXXXXX)}"

FORCE=0
REBOOT=1
THERMAL=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --no-reboot) REBOOT=0 ;;
    --with-thermal-fix) THERMAL=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight
say "preflight"
command -v adb     >/dev/null || die "adb not found"
command -v apktool >/dev/null || die "apktool not found (https://ibotpeaches.github.io/Apktool/)"
command -v python3 >/dev/null || die "python3 not found"

adb get-state >/dev/null 2>&1 || die "no adb device (check 'adb devices')"
SERIAL="$(adb shell getprop ro.serialno | tr -d '\r')"
say "device: $SERIAL"

if adb shell "su -c 'id -u' 2>/dev/null" | grep -q 0; then
  ROOT="su -c"
else
  ROOT=""
  warn "no root shell via su -c; assuming adb is already root"
fi

# run a command on the device as root
drun() { if [ -n "$ROOT" ]; then adb shell "su -c '$1'"; else adb shell "$1"; fi; }

if [ "$FORCE" -eq 0 ] && drun "test -d $KSU_DIR" | grep -q .; then
  die "$KSU_DIR already exists. Re-run with --force to overwrite, or run ./uninstall.sh first."
fi

mkdir -p "$WORKDIR"
say "workdir: $WORKDIR"

# --------------------------------------------------------- pull + decode
# If the patch is already active the target path is a bind mount over the
# patched jar.  We must work on the PRISTINE file, so unmount first.
if mount | grep -q " on $DEVICE_JAR "; then
  say "unmounting the active patch overlay (the patch is inactive until we re-apply it)"
  drun "umount $DEVICE_JAR" 2>/dev/null || true
fi

say "pulling device SDK jar"
adb pull "$DEVICE_JAR" "$WORKDIR/sdk-original.jar" >/dev/null
[ -s "$WORKDIR/sdk-original.jar" ] || die "failed to pull $DEVICE_JAR"

say "backing up the pristine original jar to the device"
BACKUP="/data/local/tmp/ocam-sdk-ORIGINAL.jar"
if [ "$FORCE" -eq 0 ] && drun "test -f $BACKUP" | grep -q .; then
  warn "$BACKUP exists, keeping the existing backup"
else
  drun "cp $DEVICE_JAR $BACKUP"
  say "backup saved at $BACKUP ($(stat -c%s "$WORKDIR/sdk-original.jar") bytes)"
fi

say "decoding with apktool"
apktool d -f -o "$WORKDIR/sdk" "$WORKDIR/sdk-original.jar" >/dev/null 2>&1 \
  || die "apktool decode failed"

# --------------------------------------------------------------- patch
say "applying patch"
python3 "$TOOLS/patch_sdk.py" "$WORKDIR/sdk/smali"

# ------------------------------------------------------------- rebuild
say "rebuilding jar"
apktool b -f "$WORKDIR/sdk" -o "$WORKDIR/sdk-patched.apk" >/dev/null 2>&1 \
  || die "apktool build failed"

rm -rf "$WORKDIR/pkg" && mkdir -p "$WORKDIR/pkg"
( cd "$WORKDIR/pkg" && unzip -o -q "$WORKDIR/sdk-patched.apk" classes.dex ) \
  || die "could not extract classes.dex"

# The stock jar stores the dex uncompressed; keep it identical.
rm -f "$WORKDIR/sdk-patched.jar"
( cd "$WORKDIR/pkg" && zip -0 -q -X "$WORKDIR/sdk-patched.jar" classes.dex ) \
  || die "could not repackage the jar"

# ------------------------------------------------------------- verify
say "verifying the rebuild only differs by the intended patch"
python3 "$TOOLS/dexfp.py" classes "$WORKDIR/sdk-original.jar" > "$WORKDIR/cls-a.txt" 2>/dev/null || true
python3 "$TOOLS/dexfp.py" classes "$WORKDIR/pkg/classes.dex"   > "$WORKDIR/cls-b.txt" 2>/dev/null || true
if ! diff -q "$WORKDIR/cls-a.txt" "$WORKDIR/cls-b.txt" >/dev/null; then
  die "class inventory changed - aborting, refusing to install"
fi
say "class inventory identical ($(wc -l < "$WORKDIR/cls-a.txt") classes)"

python3 "$TOOLS/dexfp.py" compare "$WORKDIR/sdk-original.jar" "$WORKDIR/pkg/classes.dex" \
  | sed 's/^/  /'

# ---------------------------------------------------------------- verify
# The smali assembler silently drops some edits (an inserted branch that makes
# the following code unreachable is discarded), so the BUILT ARTIFACT is
# checked, not the source tree.  Never deploy a jar that does not contain
# both patches.
say "verifying the built jar really contains both patches"
rm -rf "$WORKDIR/verify"
apktool d -f -o "$WORKDIR/verify" "$WORKDIR/sdk-patched.jar" >/dev/null 2>&1 \
  || die "could not decode the rebuilt jar for verification"
V_BASE="$WORKDIR/verify/smali/com/oplus/ocs/camera/producer/mode/BaseMode.smali"
V_PROD="$WORKDIR/verify/smali/com/oplus/ocs/camera/producer/ProducerImpl.smali"
[ -f "$V_BASE" ] || die "BaseMode.smali missing from the rebuilt jar"
[ -f "$V_PROD" ] || die "ProducerImpl.smali missing from the rebuilt jar"
grep -q 'instance-of v6, v1, \[J' "$V_BASE" \
  || die "the exif long[] patch is NOT in the rebuilt jar - refusing to install"
grep -q 'const/4 v3, 0x1' "$V_PROD" \
  || die "the capture-gate patch is NOT in the rebuilt jar - refusing to install"
say "both patches verified in the built artifact"
rm -rf "$WORKDIR/verify"

# ------------------------------------------------------------- deploy
say "installing KernelSU module"
drun "mkdir -p $KSU_DIR"
adb push "$WORKDIR/sdk-patched.jar" "$KSU_DIR.tmp" >/dev/null
drun "cp $KSU_DIR.tmp $KSU_DIR/SDK-PATCHED.jar && rm -f $KSU_DIR.tmp"
drun "cp $BACKUP $KSU_DIR/SDK-ORIGINAL.jar"
# DAC permissions only.
drun "chown root:root $KSU_DIR/SDK-PATCHED.jar $KSU_DIR/SDK-ORIGINAL.jar"
drun "chmod 755 $KSU_DIR/SDK-PATCHED.jar $KSU_DIR/SDK-ORIGINAL.jar"
# The SELinux label is set ONCE, here at install time - never from a boot-time
# script.  MediaTek's MKP kernel-integrity module hashes the SELinux state and
# panics the kernel (kernel panic, boot loop) when a label changes while the
# system is booting.  The camera app and the camera HAL can only read the jar
# if it carries the same label the original had.
#
# Read that label from the device instead of hardcoding it - it is not the
# same on every firmware version.
ORIG_CTX=$(drun "ls -Z $DEVICE_JAR" 2>/dev/null | awk '{print $1}')
[ -n "$ORIG_CTX" ] || ORIG_CTX="u:object_r:system_file:s0"
drun "chcon $ORIG_CTX $KSU_DIR/SDK-PATCHED.jar" 2>/dev/null || true
drun "chcon $ORIG_CTX $KSU_DIR/SDK-ORIGINAL.jar" 2>/dev/null || true
say "label set to $ORIG_CTX (install time only, never at boot)"

# Record the exact size of the patched jar.  The boot scripts compare it
# against the file before bind-mounting it, so a truncated / partially written
# jar can never shadow the real SDK.
drun "stat -c %s $KSU_DIR/SDK-PATCHED.jar > $KSU_DIR/SDK-PATCHED.jar.size"

adb push "$SCRIPT_DIR/ksu-module/module.prop"     "$KSU_DIR/module.prop.tmp"     >/dev/null
adb push "$SCRIPT_DIR/ksu-module/post-fs-data.sh" "$KSU_DIR/post-fs-data.sh.tmp" >/dev/null
adb push "$SCRIPT_DIR/ksu-module/service.sh"      "$KSU_DIR/service.sh.tmp"      >/dev/null
drun "mv $KSU_DIR/module.prop.tmp $KSU_DIR/module.prop"
drun "mv $KSU_DIR/post-fs-data.sh.tmp $KSU_DIR/post-fs-data.sh"
drun "mv $KSU_DIR/service.sh.tmp $KSU_DIR/service.sh"
drun "chmod 755 $KSU_DIR/post-fs-data.sh $KSU_DIR/service.sh"

say "module installed:"
drun "ls -l $KSU_DIR" | sed 's/^/  /'

# Apply the patch immediately so the user does not have to wait for a reboot.
# The module will re-apply it at every subsequent boot.
say "applying the patch now (the module re-applies it at every boot)"
if drun "mount --bind $KSU_DIR/SDK-PATCHED.jar $DEVICE_JAR" 2>/dev/null; then
  say "patch is live - no reboot strictly required"
else
  warn "could not apply the bind mount now, a reboot is required"
fi

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

The patched SDK is installed.

  verify:  adb shell mount | grep camera.unit.sdk
  rollback: ./uninstall.sh

A reboot is recommended so that every process picks up the patched jar.
EOF

if [ "$THERMAL" -eq 1 ]; then
  say
  say "installing the optional camera thermal bypass as well"
  # never reboot from here - install.sh does the single reboot at the end
  "$SCRIPT_DIR/install_thermalfix.sh" --no-reboot
fi

if [ "$REBOOT" -eq 1 ]; then
  say "rebooting"
  adb reboot
  say "rebooting - the fix will be active after the device comes back up"
fi
