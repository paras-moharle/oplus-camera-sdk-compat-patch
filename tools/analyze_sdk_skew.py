#!/usr/bin/env python3
"""
analyze_sdk_skew.py - Find the API incompatibilities between a camera APK and
the CameraUnit SDK that is actually installed on the device.

This is the tool that located the root cause of the 6.070.215 camera failure.

HOW IT WORKS
------------
1. Reads the method/field inventory of the device's
   /product/framework/com.oplus.camera.unit.sdk.jar  (and the .adapter.jar).
2. Extracts every `invoke-*` target on a `com.oplus.ocs.*` class from the
   camera APK's smali.
3. Reports which of those methods do NOT exist in the installed SDK.

Classes that the APK ships itself are skipped (the APK wins for those, the
boot class path only matters for classes it provides).

Usage:
    analyze_sdk_skew.py <apk.smali.root> <sdk.jar> [sdk.adapter.jar]
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dexfp import Dex  # noqa: E402

CALL_RE = re.compile(
    r"^(L[^;]+);->([A-Za-z0-9_<>$]+)\(([^)]*)\)")
TYPE_RE = re.compile(r"^(L[^;]+);->")


def norm(l):
    l = l.strip()
    if l.startswith("L"):
        l = l[1:]
    if l.endswith(";"):
        l = l[:-1]
    return l


PRIM = set("VZBSCIJFD")


def canon_params(p):
    """Normalise a dalvik parameter list to a canonical tuple.

    Handles the two textual dialects we see:
      smali : Ljava/lang/String;Ljava/lang/Object;
      dex   : Ljava/lang/String;,Ljava/lang/Object;
    """
    p = p.strip()
    if not p:
        return ()
    out = []
    i, n = 0, len(p)
    while i < n:
        c = p[i]
        if c == ",":
            i += 1
            continue
        if c == "L":
            j = i + 1
            while j < n and p[j] not in ";,":
                j += 1
            out.append("L" + p[i + 1:j])
            i = j + 1
            continue
        if c == "[":
            j = i
            while j < n and p[j] == "[":
                j += 1
            dims = j - i
            rest = canon_params(p[j:])
            out.append("[" * dims + (rest[0] if rest else "?"))
            k = j
            if k < n and p[k] == "L":
                k += 1
                while k < n and p[k] not in ";,":
                    k += 1
                k += 1
            else:
                k += 1
            while k < n and p[k] == ",":
                k += 1
            i = k
            continue
        if c in PRIM:
            out.append(c)
            i += 1
            continue
        j = i
        while j < n and p[j] not in ";,":
            j += 1
        out.append(p[i:j])
        i = j + 1
    return tuple(out)


def canon_sig(name, params):
    return "%s(%s)" % (name, ",".join(canon_params(params)))


def sdk_inventory(jars):
    classes, methods, supers = set(), set(), {}
    for jar in jars:
        if not os.path.isfile(jar):
            print("warning: %s not found" % jar, file=sys.stderr)
            continue
        with __import__("zipfile").ZipFile(jar) as z:
            names = [n for n in z.namelist() if n.endswith(".dex")]
            for n in names:
                data = z.read(n)
                tmp = "/tmp/_dexfp_tmp.dex"
                with open(tmp, "wb") as fh:
                    fh.write(data)
                dx = Dex(tmp)
                classes.update(norm(c) for c in dx.classes())
                for c, m, p in dx.methods():
                    # dex type descriptors look like "Ljava/lang/String;" or "I"
                    params = [t[:-1] if t.endswith(";") else t for t in p]
                    methods.add((norm(c), "%s(%s)" % (m, ",".join(params))))
                for c, s in dx.class_hierarchy().items():
                    supers[norm(c)] = norm(s) if s else None
    return classes, methods, supers


def apk_calls(smali_root):
    """Collect (class, canonical-signature) for every invoke-* in the smali."""
    calls = set()
    for dirpath, _dirs, files in os.walk(smali_root):
        for f in files:
            if not f.endswith(".smali"):
                continue
            with open(os.path.join(dirpath, f), encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = re.search(r"invoke-\w+ \{[^}]*\}, (L[^;]+);->(\S+)", line)
                    if not m:
                        continue
                    cls, rest = m.group(1), m.group(2)
                    # rest is "name(params)RETURN"
                    op = rest.find("(")
                    if op < 0:
                        continue
                    name = rest[:op]
                    close = rest.rfind(")")
                    if close < 0:
                        continue
                    params = rest[op + 1:close]
                    calls.add((cls, canon_sig(name, params)))
    return calls


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    smali_root = sys.argv[1]
    jars = sys.argv[2:]

    print("Reading device SDK: %s" % ", ".join(jars))
    sdk_classes, sdk_methods, sdk_supers = sdk_inventory(jars)
    print("  %d classes, %d methods" % (len(sdk_classes), len(sdk_methods)))

    def has_method(cls, sig):
        """Is `sig` available on `cls` (directly or inherited)?"""
        seen = set()
        cur = cls
        while cur and cur not in seen:
            seen.add(cur)
            if (cur, sig) in sdk_methods:
                return True
            cur = sdk_supers.get(cur)
        return False

    print("Reading APK smali: %s" % smali_root)
    calls = apk_calls(smali_root)
    print("  %d distinct invoke targets" % len(calls))

    missing = []
    for cls, sig in sorted(calls):
        if not cls.startswith("Lcom/oplus/ocs/"):
            continue
        ncls = norm(cls)
        if ncls not in sdk_classes:
            continue  # provided by the APK itself
        if not has_method(ncls, sig):
            missing.append((ncls, sig))

    print()
    print("=== %d methods called by the APK but MISSING from the device SDK ===" % len(missing))
    for cls, sig in missing:
        print("   %s -> %s" % (cls, sig))
    if not missing:
        print("   (none - the APK is API compatible with this SDK)")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
