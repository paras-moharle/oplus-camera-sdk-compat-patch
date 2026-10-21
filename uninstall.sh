#!/usr/bin/env bash
#
# uninstall.sh - Remove the "ocam_camfix" KernelSU module and restore the
#                stock CameraUnit SDK and the stock oplus-framework.jar.
#
# Both patches are only ever bind mounts, so removing the module and rebooting
# restores the original files exactly - nothing on disk was ever modified.
#
# Usage:
#   ./uninstall.sh              # remove the module
#   ./uninstall.sh --no-reboot  # remove it, reboot yourself later
#
set -euo pipefail

KSU_DIR="/data/adb/modules/ocam_camfix"
TARGET="/product/framework/com.oplus.camera.unit.sdk.jar"
FW_TARGET="/system/framework/oplus-framework.jar"
REBOOT=1

for a in "$@"; do
  case "$a" in
    --no-reboot) REBOOT=0 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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
drun "umount $FW_TARGET" 2>/dev/null || true

say "removing KernelSU module $KSU_DIR"
drun "rm -rf $KSU_DIR"

# The two single-purpose modules that came before the combined one.
for OLD in ocam_sdkfix ocam_thermalfix; do
  if drun "test -d /data/adb/modules/$OLD" | grep -q .; then
    say "removing the old module /data/adb/modules/$OLD"
    drun "rm -rf /data/adb/modules/$OLD"
  fi
done

say "confirming the stock jars are back in place"
drun "ls -l $TARGET" | sed 's/^/  /'
drun "sha256sum $TARGET" 2>/dev/null | sed 's/^/  /' || true
drun "ls -l $FW_TARGET" | sed 's/^/  /'
drun "sha256sum $FW_TARGET" 2>/dev/null | sed 's/^/  /' || true

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

The stock CameraUnit SDK and the stock oplus-framework.jar are restored.  A
reboot is recommended so that any already-running processes pick up the
original files.

  adb reboot
EOF

if [ "$REBOOT" -eq 1 ]; then
  say "rebooting"
  adb reboot
fi
