#!/usr/bin/env bash
#
# build_thermalfix_zip.sh - package the camera thermal bypass as a flashable
#                           KernelSU module zip.
#
#   tools/build_thermalfix_zip.sh <patched-ofw.jar> <original-ofw.jar>
#
# Flash the result in KernelSU Manager -> Modules -> Install from storage.
# It only activates on the exact firmware it was built for (the boot script
# compares the sha256 of the framework jar on disk with the reference copy in
# the module) - on any other device build it from that device's own jar with
# tools/build_framework_patch.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODDIR="$REPO_DIR/ksu-module-thermal"
OUTDIR="$REPO_DIR/release"

PATCHED="${1:-}"
ORIGINAL="${2:-}"
[ -n "$PATCHED" ]  || { echo "usage: $0 <patched.jar> <original.jar>" >&2; exit 2; }
[ -f "$PATCHED" ]  || { echo "no such file: $PATCHED" >&2; exit 1; }
[ -f "$ORIGINAL" ] || { echo "no such file: $ORIGINAL" >&2; exit 1; }

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | tr -d '\r')"
[ -n "$VERSION" ] || die "cannot read version= from module.prop"

mkdir -p "$OUTDIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "staging module files"
cp "$MODDIR/module.prop"     "$STAGE/"
cp "$MODDIR/post-fs-data.sh" "$STAGE/"
cp "$MODDIR/service.sh"      "$STAGE/"
cp "$PATCHED"                "$STAGE/PATCHED-ofw.jar"
cp "$ORIGINAL"               "$STAGE/ORIGINAL-ofw.jar"

stat -c %s "$STAGE/PATCHED-ofw.jar" > "$STAGE/PATCHED-ofw.jar.size"
chmod 755 "$STAGE/post-fs-data.sh" "$STAGE/service.sh"
chmod 644 "$STAGE"/*.jar "$STAGE"/*.size

say "zip: $OUTDIR/ocam_thermalfix-$VERSION.zip"
rm -f "$OUTDIR/ocam_thermalfix-$VERSION.zip"
( cd "$STAGE" && zip -q -r -X "$OUTDIR/ocam_thermalfix-$VERSION.zip" . ) || die "zip failed"

say "contents:"
unzip -l "$OUTDIR/ocam_thermalfix-$VERSION.zip" | sed 's/^/  /'
say "sha256:"
sha256sum "$OUTDIR/ocam_thermalfix-$VERSION.zip" | sed 's/^/  /'

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

Flash it in KernelSU Manager -> Modules -> Install from storage, then reboot.

NOTE: this zip carries a jar built from ONE specific firmware. It refuses to
mount anywhere else (sha256 guard) - on another device, build it from that
device's own /system/framework/oplus-framework.jar:
    tools/build_framework_patch.sh <jar>
EOF
