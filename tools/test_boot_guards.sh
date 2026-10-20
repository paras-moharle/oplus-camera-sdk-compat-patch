#!/usr/bin/env bash
# Local simulation of the module boot scripts (no device involved).
set -u
SRC_SCRIPT="$1"
T=$(mktemp -d)
export TESTMNT="$T/mountinfo"

MODDIR="$T/mod"
TGT="$T/tgt/com.oplus.camera.unit.sdk.jar"
mkdir -p "$MODDIR" "$T/tgt"

# build a fake "original" and "patched" sdk jar
head -c 1200000 /dev/urandom > "$T/orig.bin"
printf 'PK' | dd of="$T/orig.bin" conv=notrunc status=none
cp "$T/orig.bin" "$MODDIR/SDK-ORIGINAL.jar"
cp "$T/orig.bin" "$MODDIR/SDK-PATCHED.jar"
cp "$T/orig.bin" "$TGT"
stat -c %s "$MODDIR/SDK-PATCHED.jar" > "$MODDIR/SDK-PATCHED.jar.size"
: > "$TESTMNT"

# rewrite the script so it works on this host
sed -e "s|^MODDIR=.*|MODDIR=$MODDIR|" \
    -e "s|^TGT=.*|TGT=$TGT|" \
    -e "s|/proc/self/mountinfo|\$TESTMNT|g" \
    -e "s|^[[:space:]]*mount --bind.*|echo MOUNTED|" \
    -e "s|^[[:space:]]*log -t .*|:|" \
    "$SRC_SCRIPT" > "$T/boot.sh"

run() { sh "$T/boot.sh" 2>&1; }

check() { # name expected
  out=$(run)
  if [ "$out" = "$2" ]; then echo "  PASS  $1"; else echo "  FAIL  $1  (got '$out', want '$2')"; FAILED=1; fi
}

FAILED=0

echo "### case 1: everything matches -> must mount"
check "matching SDK mounts" "MOUNTED"

echo "### case 2: device SDK differs (different firmware) -> must NOT mount"
printf 'DIFFERENT' >> "$TGT"
check "foreign SDK refused" ""
printf 'DIFFERENT' | tr -d '\n' > /dev/null
cp "$T/orig.bin" "$TGT"   # restore

echo "### case 3: patched jar truncated -> must NOT mount"
head -c 5000 /dev/urandom > "$MODDIR/SDK-PATCHED.jar"
check "truncated patched jar refused" ""
cp "$T/orig.bin" "$MODDIR/SDK-PATCHED.jar"

echo "### case 4: no reference original -> must NOT mount"
mv "$MODDIR/SDK-ORIGINAL.jar" "$MODDIR/SDK-ORIGINAL.jar.bak"
check "missing reference refused" ""
mv "$MODDIR/SDK-ORIGINAL.jar.bak" "$MODDIR/SDK-ORIGINAL.jar"

echo "### case 5: already mounted -> exits without re-checking"
# a realistic /proc/self/mountinfo line (field 5 = mount point)
printf "398 124 254:63 /adb/modules/ocam_sdkfix/SDK-PATCHED.jar %s rw,nosuid,nodev shared:63 - f2fs /dev/block/dm-63 rw\n" "$TGT" > "$TESTMNT"
check "already mounted -> no action" ""

echo "### case 6: .size file missing, valid big zip -> still mounts"
rm -f "$MODDIR/SDK-PATCHED.jar.size"
: > "$TESTMNT"
check "no .size file, valid zip mounts" "MOUNTED"

echo "### case 7: .size file missing, big file that is not a zip -> refused"
head -c 1200000 /dev/urandom > "$MODDIR/SDK-PATCHED.jar"
check "no .size file, not a zip refused" ""

rm -rf "$T"
[ "$FAILED" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAILED
