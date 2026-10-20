#!/usr/bin/env bash
#
# build_framework_patch.sh - build the patched oplus-framework.jar used by the
#                            "ocam_thermalfix" module.
#
#   tools/build_framework_patch.sh <original-ofw.jar> [outdir]
#
# Steps:
#   1. decode the jar with apktool
#   2. patch com/oplus/util/OplusHoraeThermalHelper (camera uid only)
#   3. rebuild with apktool
#   4. repackage exactly like a real boot jar: stored (not compressed) and
#      4K aligned, because ART maps the dex straight out of the jar
#   5. verify: dex headers valid + class/method inventory identical to the
#      original (only the patched method may differ)
#
# Output: <outdir>/patched-ofw.jar  and  <outdir>/original-ofw.jar
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ORIGINAL="${1:-}"
OUTDIR="${2:-$REPO_DIR/release/thermal}"
UID_ARG="${CAMERA_UID:-}"

[ -n "$ORIGINAL" ] || { echo "usage: $0 <original-ofw.jar> [outdir]" >&2; exit 2; }
[ -f "$ORIGINAL" ] || { echo "no such file: $ORIGINAL" >&2; exit 1; }

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

command -v apktool  >/dev/null || die "apktool not found (https://ibotpeaches.github.io/Apktool/)"
command -v python3  >/dev/null || die "python3 not found"
command -v zipalign >/dev/null || die "zipalign not found (Android SDK build-tools)"

# the camera's uid, unless the caller knows better
if [ -z "$UID_ARG" ]; then
  UID_ARG=$(adb shell 'pm list packages -U com.oplus.camera' 2>/dev/null \
            | tr -d '\r' | sed -n 's/.*uid:\([0-9]*\).*/\1/p' | head -1)
  [ -n "$UID_ARG" ] || UID_ARG=10155
fi
say "camera uid: $UID_ARG"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTDIR"

say "decoding $(basename "$ORIGINAL")"
apktool d -f -o "$WORK/ofw" "$ORIGINAL" >/dev/null 2>&1 || die "apktool decode failed"

say "patching the thermal helper"
python3 "$SCRIPT_DIR/patch_thermal_bypass.py" "$WORK/ofw/smali" --uid "$UID_ARG"

say "rebuilding"
apktool b -f "$WORK/ofw" -o "$WORK/patched.apk" >/dev/null 2>&1 || die "apktool build failed"

say "repacking (stored + 4K aligned, like a real boot jar)"
mkdir -p "$WORK/pkg" "$WORK/stage"
( cd "$WORK/pkg" && unzip -q -o "$WORK/patched.apk" "classes*.dex" )
( cd "$WORK/stage" \
  && unzip -q -o "$ORIGINAL" META-INF/MANIFEST.MF 2>/dev/null || true
  cd "$WORK/stage" && cp "$WORK/pkg"/classes*.dex .
  cd "$WORK/stage" && zip -0 -q -X "$WORK/patched-ofw.jar" $(ls | grep -E 'MANIFEST.MF|classes.*\.dex')
)
zipalign -p -f 4 "$WORK/patched-ofw.jar" "$WORK/patched-aligned.jar"
mv "$WORK/patched-aligned.jar" "$OUTDIR/patched-ofw.jar"
cp "$ORIGINAL" "$OUTDIR/original-ofw.jar"

say "verifying the rebuild"
python3 - "$OUTDIR/patched-ofw.jar" "$ORIGINAL" <<'PY'
import hashlib, struct, sys, zipfile, zlib
jar, orig = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(jar)
zo = zipfile.ZipFile(orig)
ok = True
for name in [n for n in z.namelist() if n.endswith('.dex')]:
    d = z.read(name)
    magic_ok = d[:4] == b"dex\n"
    size_ok = struct.unpack("<I", d[32:36])[0] == len(d)
    adler_ok = (zlib.adler32(d[12:]) & 0xffffffff) == struct.unpack("<I", d[8:12])[0]
    sha1_ok = hashlib.sha1(d[32:]).hexdigest() == d[12:32].hex()
    print(f"  {name}: magic={magic_ok} size={size_ok} adler32={adler_ok} sha1={sha1_ok}")
    ok = ok and magic_ok and size_ok and adler_ok and sha1_ok
    # the dex must have the same number of entries as the original
    o = zo.read(name) if name in zo.namelist() else None
    if o is not None:
        print(f"    original {name}: {len(o)} bytes, patched: {len(d)} bytes")
sys.exit(0 if ok else "DEX INVALID")
PY

say "class / method inventory vs the original"
rm -rf "$WORK/vold" "$WORK/vnew"
mkdir -p "$WORK/vold" "$WORK/vnew"
( cd "$WORK/vold" && unzip -q -o "$ORIGINAL" "classes*.dex" )
( cd "$WORK/vnew" && unzip -q -o "$OUTDIR/patched-ofw.jar" "classes*.dex" )
for d in "$WORK/vold"/classes*.dex; do
  b=$(basename "$d")
  python3 "$SCRIPT_DIR/dexfp.py" classes "$d" > "$WORK/old.txt" 2>/dev/null || true
  python3 "$SCRIPT_DIR/dexfp.py" classes "$WORK/vnew/$b" > "$WORK/new.txt" 2>/dev/null || true
  if diff -q "$WORK/old.txt" "$WORK/new.txt" >/dev/null; then
    echo "  $b: class inventory identical ($(wc -l < "$WORK/old.txt") classes)"
  else
    die "  $b: CLASS INVENTORY CHANGED - refusing to ship"
  fi
  python3 "$SCRIPT_DIR/dexfp.py" inventory "$d" > "$WORK/oldm.txt" 2>/dev/null || true
  python3 "$SCRIPT_DIR/dexfp.py" inventory "$WORK/vnew/$b" > "$WORK/newm.txt" 2>/dev/null || true
  if diff -q "$WORK/oldm.txt" "$WORK/newm.txt" >/dev/null; then
    echo "  $b: method inventory identical ($(wc -l < "$WORK/oldm.txt") methods)"
  else
    die "  $b: METHOD INVENTORY CHANGED - refusing to ship"
  fi
done

say "output:"
ls -l "$OUTDIR" | sed 's/^/  /'
sha256sum "$OUTDIR"/*.jar | sed 's/^/  /'
