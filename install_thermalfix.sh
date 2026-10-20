#!/usr/bin/env bash
#
# install_thermalfix.sh - install the "ocam_thermalfix" KernelSU module.
#
# WHAT IT DOES
# ------------
#   1. pulls /system/framework/oplus-framework.jar off the device
#   2. patches com/oplus/util/OplusHoraeThermalHelper so that the CAMERA
#      PROCESS ONLY (uid detected from the device) sees a capped skin
#      temperature (30 degC / thermal level 0) instead of the real one
#   3. rebuilds the jar and verifies that the class/method inventory is
#      unchanged
#   4. installs a KernelSU module that bind-mounts the patched jar over the
#      original at every boot
#
# WHY
# ---
# Camera 6.070.215 (and the stock 6.020.980) hard-code a capture temperature
# threshold of 41 degC and compare it against the skin temperature reported by
# Oplus' "horae" service.  A phone that idles at 41-44 degC is therefore
# *permanently* above that threshold, so every capture is deferred (3-6 s),
# the preview is degraded and video recording is refused.  The threshold
# cannot be changed by configuration - the OEM code has a key/lookup type
# mismatch that always falls back to the hard-coded default.
#
# The original file on disk is NEVER modified - this is a bind mount.
#
# Usage:
#   ./install_thermalfix.sh                # install + reboot
#   ./install_thermalfix.sh --no-reboot    # install, reboot yourself later
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$SCRIPT_DIR/tools"
KSU_DIR="/data/adb/modules/ocam_thermalfix"
DEVICE_JAR="/system/framework/oplus-framework.jar"
WORKDIR="${WORKDIR:-$(mktemp -d /tmp/ocam-thermal-XXXXXX)}"

REBOOT=1
for a in "$@"; do
  case "$a" in
    --no-reboot) REBOOT=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
command -v zipalign >/dev/null || die "zipalign not found (Android SDK build-tools)"

adb get-state >/dev/null 2>&1 || die "no adb device (check 'adb devices')"
SERIAL="$(adb shell getprop ro.serialno | tr -d '\r')"
say "device: $SERIAL"

if adb shell "su -c 'id -u' 2>/dev/null" | grep -q 0; then
  ROOT="su -c"
else
  ROOT=""
  warn "no root shell via su -c; assuming adb is already root"
fi
drun() { if [ -n "$ROOT" ]; then adb shell "su -c '$1'"; else adb shell "$1"; fi; }

mkdir -p "$WORKDIR"

# --------------------------------------------------------- pull + build
say "pulling $DEVICE_JAR"
adb pull "$DEVICE_JAR" "$WORKDIR/original-ofw.jar" >/dev/null
[ -s "$WORKDIR/original-ofw.jar" ] || die "failed to pull $DEVICE_JAR"

say "building the patched framework jar"
"$TOOLS/build_framework_patch.sh" "$WORKDIR/original-ofw.jar" "$WORKDIR/out"

# --------------------------------------------------------- deploy
say "installing KernelSU module"
drun "mkdir -p $KSU_DIR"
adb push "$WORKDIR/out/patched-ofw.jar"  "$KSU_DIR/PATCHED-ofw.jar.tmp"  >/dev/null
adb push "$WORKDIR/out/original-ofw.jar" "$KSU_DIR/ORIGINAL-ofw.jar.tmp" >/dev/null
drun "mv $KSU_DIR/PATCHED-ofw.jar.tmp  $KSU_DIR/PATCHED-ofw.jar"
drun "mv $KSU_DIR/ORIGINAL-ofw.jar.tmp $KSU_DIR/ORIGINAL-ofw.jar"

for f in module.prop post-fs-data.sh service.sh; do
  adb push "$SCRIPT_DIR/ksu-module-thermal/$f" "$KSU_DIR/$f.tmp" >/dev/null
  drun "mv $KSU_DIR/$f.tmp $KSU_DIR/$f"
done
drun "chmod 755 $KSU_DIR/post-fs-data.sh $KSU_DIR/service.sh"
drun "chown root:root $KSU_DIR/PATCHED-ofw.jar $KSU_DIR/ORIGINAL-ofw.jar"
drun "chmod 644 $KSU_DIR/PATCHED-ofw.jar $KSU_DIR/ORIGINAL-ofw.jar"

# The SELinux label is set ONCE, here at install time - never from a boot-time
# script.  MediaTek's MKP kernel-integrity module panics the kernel when a
# label changes while the system is booting.  The label is copied from the
# ORIGINAL jar: the zygote opens the bootclasspath at boot and must be able to
# read it, otherwise the phone boot-loops.
ORIG_CTX=$(drun "ls -Z $DEVICE_JAR" | awk '{print $1}')
[ -n "$ORIG_CTX" ] || ORIG_CTX="u:object_r:system_file:s0"
drun "chcon $ORIG_CTX $KSU_DIR/PATCHED-ofw.jar" 2>/dev/null || true
drun "chcon $ORIG_CTX $KSU_DIR/ORIGINAL-ofw.jar" 2>/dev/null || true
say "label set to $ORIG_CTX (install time only, never at boot)"

drun "stat -c %s $KSU_DIR/PATCHED-ofw.jar > $KSU_DIR/PATCHED-ofw.jar.size"

say "module installed:"
drun "ls -l $KSU_DIR" | sed 's/^/  /'

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

The thermal bypass is installed.  It becomes active at the next boot (the
bind mount has to happen before the zygote opens the bootclasspath).

  verify:  adb shell mount | grep oplus-framework
  rollback: ./uninstall.sh --thermal
EOF

if [ "$REBOOT" -eq 1 ]; then
  say "rebooting"
  adb reboot
  say "rebooting - the thermal bypass is active after the device comes back up"
fi
