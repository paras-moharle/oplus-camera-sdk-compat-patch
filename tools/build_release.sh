#!/usr/bin/env bash
#
# build_release.sh - Assemble the flashable KernelSU module zip.
#
# WHAT IT DOES
# ------------
#   Takes the patched SDK jar (and the pristine original) and packages them
#   together with the module scripts into
#
#       release/ocam_sdkfix-<version>.zip
#
#   The zip is what you flash in KernelSU Manager -> Modules -> Install from
#   storage.  Nothing is downloaded and nothing proprietary is committed to
#   the repository: the jars you pass in are the ones you built from your own
#   device with install.sh.
#
# Usage:
#   tools/build_release.sh <patched.jar> [original.jar]
#
#   patched.jar   the rebuilt SDK jar (install.sh leaves it in the workdir)
#   original.jar  the pristine SDK jar (optional; only kept in the module for
#                 reference / manual rollback)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MODDIR="$REPO_DIR/ksu-module"
OUTDIR="$REPO_DIR/release"

PATCHED_JAR="${1:-}"
ORIGINAL_JAR="${2:-}"

[ -n "$PATCHED_JAR" ] || { echo "usage: $0 <patched.jar> [original.jar]" >&2; exit 2; }
[ -f "$PATCHED_JAR" ] || { echo "no such file: $PATCHED_JAR" >&2; exit 1; }

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="$(sed -n 's/^version=//p' "$MODDIR/module.prop" | tr -d '\r')"
[ -n "$VERSION" ] || die "cannot read version= from $MODDIR/module.prop"

say "module version: $VERSION"
mkdir -p "$OUTDIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

say "staging module files"
cp "$MODDIR/module.prop"     "$STAGE/"
cp "$MODDIR/post-fs-data.sh" "$STAGE/"
cp "$MODDIR/service.sh"      "$STAGE/"
cp "$PATCHED_JAR"            "$STAGE/SDK-PATCHED.jar"

if [ -n "$ORIGINAL_JAR" ] && [ -f "$ORIGINAL_JAR" ]; then
  cp "$ORIGINAL_JAR" "$STAGE/SDK-ORIGINAL.jar"
else
  warn "no original jar given - the module will not carry a reference copy"
fi

# The boot scripts compare this against the jar before mounting it.
stat -c %s "$STAGE/SDK-PATCHED.jar" > "$STAGE/SDK-PATCHED.jar.size"

chmod 755 "$STAGE/post-fs-data.sh" "$STAGE/service.sh"

say "zip: $OUTDIR/ocam_sdkfix-$VERSION.zip"
rm -f "$OUTDIR/ocam_sdkfix-$VERSION.zip"
( cd "$STAGE" && zip -q -r -X "$OUTDIR/ocam_sdkfix-$VERSION.zip" . ) \
  || die "zip failed"

say "contents:"
unzip -l "$OUTDIR/ocam_sdkfix-$VERSION.zip" | sed 's/^/  /'

say "sha256:"
sha256sum "$OUTDIR/ocam_sdkfix-$VERSION.zip" | sed 's/^/  /'

cat <<EOF

$(printf '\033[1;32m*** DONE ***\033[0m')

Flash it in KernelSU Manager -> Modules -> Install from storage, then reboot.

  adb shell mount | grep camera.unit.sdk     # verify after the reboot
EOF
