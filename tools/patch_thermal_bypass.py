#!/usr/bin/env python3
"""
patch_thermal_bypass.py - stop the Oplus camera from thermally deferring captures.

THE PROBLEM
-----------
Oplus camera 6.070.215 (and the stock 6.020.980) hard-code the capture
temperature threshold in the app:

    qc/a2.smali:  const-string v2, "41"     # common_capture_temperature_threshold
    ka/m1.smali:  const-string v2, "41"     # (stock build, same value)

and compare it against the skin temperature reported by Oplus' "horae"
thermal service:

    dumpsys horae  ->  Temp: 41.53

Because 41.53 > 41 the camera's capture-defer logic engages *permanently* on
a phone whose skin sits at 41-44 degC: every capture is deferred (3-6 s),
the preview is degraded and video recording is refused.

The threshold cannot be overridden by configuration: the OEM code fills a
map keyed by the *label string* but looks it up with the *enum object*
(qc/s.b()), so the lookup always misses and the hard-coded default "41" is
always used.  The config file it would read
(/odm/etc/camera/config/oplus_camera_feature_config) does not even exist on
this firmware.

THE FIX
-------
Patch the framework that owns the temperature source:

    /system/framework/oplus-framework.jar
      com/oplus/util/OplusHoraeThermalHelper
        getCurrentThermal()F   ->  returns the real skin temperature
        getThermalStatus()I    ->  returns the real horae level

For the camera process only (uid given on the command line) they now return a
capped value (30.0f / 0), i.e. the camera behaves as if the phone were cool.
Every other process still sees the real values, so battery charging limits,
game mode and the thermal governor keep working normally.

The jar is patched and bind-mounted over the original (the file on disk is
never modified), exactly like the CameraUnit SDK patch.
"""

import argparse
import os
import re
import struct
import sys

TARGET = "com/oplus/util/OplusHoraeThermalHelper.smali"


def die(msg):
    print("ERROR: %s" % msg, file=sys.stderr)
    sys.exit(1)


def patch_method(lines, method_sig, uids, label_hit, label_miss, body, marker):
    """Insert a UID-guarded early return at the start of a method."""
    start = None
    for i, l in enumerate(lines):
        if l.startswith(".method") and method_sig in l:
            start = i
            break
    if start is None:
        die("method %s not found" % method_sig)

    # find the end of the .locals directive to know the register budget
    locals_n = 0
    for i in range(start, min(start + 8, len(lines))):
        m = re.match(r"^\s*\.locals (\d+)\s*$", lines[i])
        if m:
            locals_n = int(m.group(1))
            break
    if locals_n < 2:
        die("method %s has too few locals (%d)" % (method_sig, locals_n))

    # insert right after the .locals line
    ins = start
    for i in range(start, min(start + 8, len(lines))):
        if re.match(r"^\s*\.locals \d+\s*$", lines[i]):
            ins = i + 1
            break

    block = [
        "",
        "    # --- camera thermal bypass (patched) ---",
        "    invoke-static {}, Landroid/os/Process;->myUid()I",
        "    move-result v0",
    ]
    for uid in uids:
        block += [
            "    const/16 v1, 0x%x" % uid,
            "    if-eq v0, v1, %s" % label_hit,
        ]
    block += [
        "    goto %s" % label_miss,
        "    %s" % label_hit,
        "    %s" % body,
        "    %s" % marker,
        "    %s" % label_miss,
        "    # --- end camera thermal bypass ---",
        "",
    ]
    lines[ins:ins] = block
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("smali_root", help="decoded framework root (contains com/oplus/...)")
    ap.add_argument("--uid", action="append", type=int, default=None,
                    help="uid of a process that gets the capped values; repeatable. "
                         "Default: 10155 (com.oplus.camera) only - the AI unit "
                         "must keep seeing the real temperature")
    ap.add_argument("--temp", default="30.0",
                    help="temperature reported to that process, in degC. Must stay "
                         "below the camera's own capture threshold (41 degC) so "
                         "captures are not deferred")
    ap.add_argument("--status", type=int, default=13,
                    help="thermal status reported to that process. The camera "
                         "only uses the AI/EAP capture path when this is < 13; "
                         "13+ makes it take the plain capture path, which is the "
                         "one that works on this firmware")
    ap.add_argument("--check", action="store_true",
                    help="only report whether the patch is present")
    args = ap.parse_args()

    uids = args.uid if args.uid else [10155]
    path = os.path.join(args.smali_root, TARGET)
    if not os.path.isfile(path):
        die("not found: %s" % path)

    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.split("\n")

    if "camera thermal bypass (patched)" in text:
        print("  [skip] already patched")
        return 0

    if args.check:
        print("  unpatched")
        return 1

    # 30.0f = 0x41f00000
    bits = float(args.temp)
    temp_bits = struct.unpack("<I", struct.pack("<f", bits))[0]
    body_f = "const/high16 v0, 0x%x" % temp_bits

    lines = patch_method(
        lines, "getCurrentThermal()F", uids,
        ":ocam_thermal_bypass", ":ocam_no_thermal_bypass",
        body_f, "return v0")
    lines = patch_method(
        lines, "getThermalStatus()I", uids,
        ":ocam_thermal_bypass_status", ":ocam_no_thermal_bypass_status",
        "const/16 v0, 0x%x" % args.status, "return v0")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))

    print("  [ok] patched %s for uid(s) %s (temp=%s degC, status=%d)"
          % (TARGET, ",".join(str(u) for u in uids), args.temp, args.status))
    return 0


if __name__ == "__main__":
    sys.exit(main())
