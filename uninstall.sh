#!/usr/bin/env bash
#
# uninstall.sh - Remove the CameraUnit SDK compat patch and restore the
#                stock (unpatched) CameraUnit SDK.
#
# The patch is only ever a bind mount, so removing the module and rebooting
# restores the original jar exactly - the file on disk was never modified.
#
# Usage:
#   ./uninstall.sh              # remove the SDK patch
#   ./uninstall.sh --thermal    # also remove the optional camera thermal bypass
#
set -euo pipefail

KSU_DIR="/data/adb/modules/ocam_sdkfix"
THERMAL_DIR="/data/adb/modules/ocam_thermalfix"
TARGET="/product/framework/com.oplus.camera.unit.sdk.jar"
FW_TARGET="/system/framework/oplus-framework.jar"
REBOOT=1
THERMAL=0

for a in "$@"; do
  case "$a" in
    --no-reboot) REBOOT=0 ;;
    --thermal) THERMAL=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

command -v adb >/dev/null || die "adb not found"
adb get-state >/dev/null 2>&1 || die "no adb device"

if adb shell "su -c 'id -u' 2>/dev/null" | grep -q 0; then
  drun() { adb shell "su -c '$1'"; }
else
  drun() { adb shell "$1"; }
fi

say "unmounting any active overlay"
drun "umount $TARGET" 2>/dev/null || true

say "removing KernelSU module $KSU_DIR"
drun "rm -rf $KSU_DIR"

if [ "$THERMAL" -eq 1 ]; then
  say "unmounting the camera thermal bypass overlay"
  drun "umount $FW_TARGET" 2>/dev/null || true
  say "removing KernelSU module $THERMAL_DIR"
  drun "rm -rf $THERMAL_DIR"
  say "confirming the stock framework jar is back in place"
  drun "ls -l $FW_TARGET" | sed 's/^/  /'
  drun "sha256sum $FW_TARGET" 2>/dev/null | sed 's/^/  /' || true
fi

say "confirming the stock jar is back in place"
drun "ls -l $TARGET" | sed 's/^/  /'
drun "sha256sum $TARGET" 2>/dev/null | sed 's/^/  /' || true

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

The stock CameraUnit SDK is restored.  A reboot is recommended so that any
already-running processes pick up the original jar.

  adb reboot
EOF

if [ "$REBOOT" -eq 1 ]; then
  say "rebooting"
  adb reboot
fi
