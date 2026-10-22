#!/usr/bin/env bash
#
# build_release.sh - Assemble the flashable KernelSU module zip.
#
# WHAT IT DOES
# ------------
#   Takes the patched SDK jar (and the pristine original) and packages them
#   together with the module scripts into
#
#       release/<module-id>-<version>.zip
#
#   The zip is what you flash in KernelSU Manager -> Modules -> Install from
#   storage.  Nothing is downloaded and nothing proprietary is committed to
#   the repository: the jars you pass in are the ones you built from your own
#   device with install.sh.
#
# Usage:
#   tools/build_release.sh <patched-sdk.jar> [original-sdk.jar] [patched-ofw.jar]
#
#   patched-sdk.jar  the rebuilt CameraUnit SDK jar
#   original-sdk.jar the pristine CameraUnit SDK jar (optional; only kept in
#                    the module for reference / manual rollback)
#   patched-ofw.jar  the rebuilt oplus-framework.jar (the thermal bypass).
#                    Optional - without it the module still works, the thermal
#                    bypass is simply not active.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODDIR="$REPO_DIR/ksu-module"
OUTDIR="$REPO_DIR/release"

PATCHED_JAR="${1:-}"
ORIGINAL_JAR="${2:-}"
PATCHED_OFW="${3:-}"

[ -n "$PATCHED_JAR" ] || { echo "usage: $0 <patched.jar> [original.jar]" >&2; exit 2; }
[ -f "$PATCHED_JAR" ] || { echo "no such file: $PATCHED_JAR" >&2; exit 1; }

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | tr -d '\r')"
[ -n "$VERSION" ] || die "cannot read version= from $MODDIR/module.prop"
MODID="$(sed -n 's/^id=//p' "$MODDIR/module.prop" | tr -d '\r')"
[ -n "$MODID" ] || die "cannot read id= from $MODDIR/module.prop"

say "module version: $VERSION"
mkdir -p "$OUTDIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "staging module files"
cp "$MODDIR/module.prop"     "$STAGE/"
cp "$MODDIR/post-fs-data.sh" "$STAGE/"
cp "$MODDIR/service.sh"      "$STAGE/"
cp "$MODDIR/boot-completed.sh" "$STAGE/"
cp "$MODDIR/sepolicy.rule"   "$STAGE/"
cp "$PATCHED_JAR"            "$STAGE/SDK-PATCHED.jar"

# The NoMount redirect tree.  NoMount's metamount.sh runs at boot, walks every
# module's product/ (and system/ etc.) tree and injects a kernel VFS rule that
# maps the OEM path to the file here.  This is what makes the camera load the
# patched jar in EVERY mount namespace - a bind mount is stripped from the
# app's namespace and never reaches the camera.
mkdir -p "$STAGE/product/framework/oat/arm64"
cp "$PATCHED_JAR" "$STAGE/product/framework/com.oplus.camera.unit.sdk.jar"
# Zero-length files: they hide the OEM's prebuilt dexopt artifacts, which were
# compiled from the STOCK jar, so ART must extract the dex from our jar.
: > "$STAGE/product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex"
: > "$STAGE/product/framework/oat/arm64/com.oplus.camera.unit.sdk.odex"

if [ -n "$ORIGINAL_JAR" ] && [ -f "$ORIGINAL_JAR" ]; then
  cp "$ORIGINAL_JAR" "$STAGE/SDK-ORIGINAL.jar"
else
  warn "no original jar given - the module will not carry a reference copy"
fi

if [ -n "$PATCHED_OFW" ] && [ -f "$PATCHED_OFW" ]; then
  cp "$PATCHED_OFW" "$STAGE/PATCHED-ofw.jar"
else
  warn "no patched framework jar given - the thermal bypass will not be active"
fi

# The boot scripts compare this against the jar before mounting it.
stat -c %s "$STAGE/SDK-PATCHED.jar" > "$STAGE/SDK-PATCHED.jar.size"
if [ -f "$STAGE/PATCHED-ofw.jar" ]; then
  stat -c %s "$STAGE/PATCHED-ofw.jar" > "$STAGE/PATCHED-ofw.jar.size"
fi

chmod 755 "$STAGE/post-fs-data.sh" "$STAGE/service.sh" "$STAGE/boot-completed.sh"

say "zip: $OUTDIR/$MODID-$VERSION.zip"
rm -f "$OUTDIR/$MODID-$VERSION.zip"
( cd "$STAGE" && zip -q -r -X "$OUTDIR/$MODID-$VERSION.zip" . ) \
  || die "zip failed"

say "contents:"
unzip -l "$OUTDIR/$MODID-$VERSION.zip" | sed 's/^/  /'

say "sha256:"
sha256sum "$OUTDIR/$MODID-$VERSION.zip" | sed 's/^/  /'

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

Flash it in KernelSU Manager -> Modules -> Install from storage, then reboot.

  adb shell su -c 'stat -Lc %s /product/framework/com.oplus.camera.unit.sdk.jar'
        -> must print the size of the patched jar (not the OEM one)

  hold volume-down for 2 s  ->  toggle the thermal bypass
  hold volume-up   for 2 s  ->  show the state
EOF
