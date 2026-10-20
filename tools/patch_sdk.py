#!/usr/bin/env python3
"""
patch_sdk.py - Apply the 'picture_exif_flag' long[] compatibility patch to a
decoded com.oplus.camera.unit.sdk.jar smali tree.

WHAT IT DOES
------------
Camera 6.070.215 (and newer) declares the capture parameter
"com.oplus.picture.exif.flag" with the Java type  long[]  (const-class [J),
while camera 6.020.980 and older declared it as int[]  (const-class [I).

The stock CameraUnit SDK (com.oplus.ocs.camera.producer.mode.BaseMode) reads
that parameter back with:

    int[] exif = (int[]) builder.get(UTakePictureKeys.KEY_PICTURE_EXIF_FLAG);

which throws

    java.lang.ClassCastException: long[] cannot be cast to int[]

inside ProducerImpl.takePicture() -> the still-capture request is never built,
the capture is cancelled, and no photo is written.

This script rewrites that single read so it accepts BOTH int[] and long[].
Everything else in the jar is left untouched.

SAFETY
------
* Idempotent      - if the patch is already present, it is a no-op.
* Non-destructive - it never deletes or rewrites unrelated code; it only
                    replaces one contiguous instruction block.
* Verifiable      - the caller can diff the class/method inventory of the
                    rebuilt dex against the original (see tools/dexfp.py).
* Aborts loudly   - if the expected code is not found (different SDK version),
                    nothing is written.
"""

import argparse
import os
import re
import sys

TARGET_REL = "com/oplus/ocs/camera/producer/mode/BaseMode.smali"

# The block we replace: the int[] cast and the use of element [0].
# (`.line` debug markers are interleaved in the real file and are preserved by
#  the caller's line-based splice.)
#
# The patched block: accept int[] (original behaviour) OR long[] (new camera).
NEW_BLOCK = """\
    move-result-object v1

    instance-of v6, v1, [J

    if-eqz v6, :opplus_exif_flag_int_array

    check-cast v1, [J

    const/4 v6, 0x0

    aget-wide v2, v1, v6

    long-to-int v2, v2

    iput v2, p2, Lcom/oplus/ocs/camera/common/util/CameraRequestTag;->mExif:I

    goto {skip}

    :opplus_exif_flag_int_array
    check-cast v1, [I

    if-eqz v1, {skip}

    array-length v2, v1

    if-lez v2, {skip}

    aget v1, v1, v0

    iput v1, p2, Lcom/oplus/ocs/camera/common/util/CameraRequestTag;->mExif:I
"""

PATCHED_MARKERS = (":opplus_exif_flag_int_array", ":opplus_exif_int_array")


def is_patched(lines):
    return any(any(m in l for m in PATCHED_MARKERS) for l in lines)


def die(msg):
    print("ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def find_skip_label(lines, start, end):
    """Return the label the 'not set' path jumps to.

    In the stock SDK the code reads:

        check-cast v1, [I
        if-eqz v1, :cond_0
        ...
        iput v1, p2, ...->mExif:I
        :cond_0

    i.e. the label that follows the mExif store. We locate it by finding the
    first `if-eqz v1, <label>` inside the block and verifying the label exists
    after the block.
    """
    m = re.search(r"if-eqz v1, (:\w+)", "\n".join(lines[start:end]))
    if not m:
        return None
    label = m.group(1)
    for i in range(end, min(end + 40, len(lines))):
        if lines[i].strip() == label:
            return label
    return None


def patch_file(path):
    if not os.path.isfile(path):
        die("smali file not found: %s" % path)

    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    if is_patched(lines):
        print("  [skip] already patched (marker present)")
        return "already-patched"

    # Locate the method that reads KEY_PICTURE_EXIF_FLAG and casts it to int[].
    # Be careful: there are many synthetic `lambda$updateCaptureRequestTag$NN`
    # methods, so match the real declaration, and fall back to a content-based
    # search if the method was renamed in some other SDK build.
    mstart = mend = None
    decl = re.compile(r"^\.method\s+.*?\bupdateCaptureRequestTag\(")
    for i, l in enumerate(lines):
        if decl.match(l):
            mstart = i
            break
    if mstart is None:
        # content-based fallback
        for i, l in enumerate(lines):
            if "KEY_PICTURE_EXIF_FLAG" in l and l.strip().startswith("sget-object"):
                for j in range(i, len(lines)):
                    if lines[j].startswith(".method "):
                        mstart = j
                        break
                break
    if mstart is None:
        die("could not locate the KEY_PICTURE_EXIF_FLAG read in %s "
            "(this SDK version is not the expected one)" % path)
    for i in range(mstart, len(lines)):
        if lines[i].startswith(".end method"):
            mend = i
            break

    # find the index of the sget of KEY_PICTURE_EXIF_FLAG
    key_idx = None
    for i in range(mstart, mend):
        if "KEY_PICTURE_EXIF_FLAG" in lines[i] and "sget-object" in lines[i]:
            key_idx = i
            break
    if key_idx is None:
        die("KEY_PICTURE_EXIF_FLAG read not found in updateCaptureRequestTag")

    # find the check-cast v1, [I that follows it
    cast_idx = None
    for i in range(key_idx, min(key_idx + 30, mend)):
        if lines[i].strip() == "check-cast v1, [I":
            cast_idx = i
            break
    if cast_idx is None:
        die("'check-cast v1, [I' not found after KEY_PICTURE_EXIF_FLAG")

    # the mExif store that closes the block
    store_idx = None
    for i in range(cast_idx, mend):
        if "CameraRequestTag;->mExif:I" in lines[i] and "iput" in lines[i]:
            store_idx = i
            break
    if store_idx is None:
        die("mExif store not found")

    # we must not duplicate the 'move-result-object v1' that precedes the cast
    result_idx = None
    for i in range(cast_idx - 1, key_idx - 1, -1):
        if lines[i].strip() == "move-result-object v1":
            result_idx = i
            break
    if result_idx is None:
        die("'move-result-object v1' not found before the cast")

    skip = find_skip_label(lines, cast_idx, store_idx)
    if skip is None:
        die("could not determine the skip label for the mExif block")

    # Build the replacement: from the 'move-result-object v1' up to the store.
    # The new block is intentionally longer (it adds a type test); the dex is
    # rebuilt from scratch afterwards, so the size change is fine.
    new = NEW_BLOCK.replace("{skip}", skip).split("\n")
    old = lines[result_idx:store_idx + 1]

    # Safety: the block must contain the expected statements.
    joined_old = "\n".join(old)
    for must in ("check-cast v1, [I", "aget v1, v1, v0", "->mExif:I"):
        if must not in joined_old:
            die("unexpected block content (missing %r) - aborting" % must)

    lines[result_idx:store_idx + 1] = new

    # Make sure the method still has enough registers: we use v6 and the
    # v2/v3 wide pair. The stock method has .locals 10 + 3 params = 13
    # registers (v0..v12), so v6 and v2/v3 are safe. Bump .locals if a
    # future SDK version reduced it.
    for i in range(mstart, mend):
        m = re.match(r"^(\s*)\.locals (\d+)\s*$", lines[i])
        if m:
            n = int(m.group(2))
            if n < 8:
                lines[i] = "%s.locals 8" % m.group(1)
                print("  [info] raised .locals %d -> 8" % n)
            break

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print("  [ok] patched updateCaptureRequestTag in %s (skip label %s)"
          % (os.path.basename(path), skip))
    return "patched"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("smali_dir", help="decoded sdk smali root (contains com/oplus/...)")
    ap.add_argument("--check", action="store_true",
                    help="only report whether the patch is present, change nothing")
    args = ap.parse_args()

    target = os.path.join(args.smali_dir, TARGET_REL)
    if args.check:
        if not os.path.isfile(target):
            die("not found: %s" % target)
        with open(target, encoding="utf-8") as fh:
            state = "patched" if is_patched(fh.read().split("\n")) else "unpatched"
        print("%s: %s" % (target, state))
        sys.exit(0 if state == "patched" else 1)

    print("Patching %s" % target)
    patch_file(target)
    print("Done.")


if __name__ == "__main__":
    main()
