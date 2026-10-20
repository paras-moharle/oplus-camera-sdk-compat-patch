#!/usr/bin/env python3
"""
dexfp.py - Minimal DEX reader used to fingerprint a dex file.

Used to PROVE that a rebuilt jar only differs from the original by the
intended patch: we compare the full inventory of classes and methods
(plus a hash of the sorted inventory) before and after.

No third-party dependencies, no Android SDK required.

Usage:
    dexfp.py inventory  <file.dex>          # print sorted "class->method" list
    dexfp.py classes    <file.dex>          # print sorted class list
    dexfp.py fingerprint <file.dex>         # print a single sha256 of the inventory
    dexfp.py compare    <a.dex> <b.dex>    # exit 0 if inventories are identical
"""

import hashlib
import os
import struct
import sys
import zipfile


def _read_dex(path):
    """Return the bytes of the dex inside `path` (a .dex, .jar or .apk)."""
    with open(path, "rb") as fh:
        head = fh.read(4)
    if head == b"dex\n":
        with open(path, "rb") as fh:
            return fh.read()
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.endswith(".dex")]
        if not names:
            raise ValueError("no classes.dex inside %s" % path)
        if len(names) > 1:
            print("warning: %s contains %d dex files, using %s"
                  % (path, len(names), names[0]), file=sys.stderr)
        return z.read(names[0])


class Dex:
    def __init__(self, path):
        self.d = _read_dex(path)
        if self.d[:4] != b"dex\n":
            raise ValueError("not a dex file: %s" % path)
        (self.string_ids_size, self.string_ids_off) = struct.unpack_from("<II", self.d, 0x38)
        (self.type_ids_size, self.type_ids_off) = struct.unpack_from("<II", self.d, 0x40)
        (self.proto_ids_size, self.proto_ids_off) = struct.unpack_from("<II", self.d, 0x48)
        (self.method_ids_size, self.method_ids_off) = struct.unpack_from("<II", self.d, 0x58)
        (self.class_defs_size, self.class_defs_off) = struct.unpack_from("<II", self.d, 0x60)

    # --- string pool -----------------------------------------------------
    def string(self, idx):
        off = struct.unpack_from("<I", self.d, self.string_ids_off + idx * 4)[0]
        # uleb128 length
        shift = 0
        size = 0
        while True:
            b = self.d[off]
            off += 1
            size |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
        end = self.d.index(b"\x00", off)
        return self.d[off:end].decode("utf-8", "replace")

    def type_str(self, idx):
        sidx = struct.unpack_from("<I", self.d, self.type_ids_off + idx * 4)[0]
        return self.string(sidx)

    # --- protos ----------------------------------------------------------
    def proto(self, idx):
        _shorty, _ret, params_off = struct.unpack_from("<III", self.d, self.proto_ids_off + idx * 12)
        params = []
        if params_off:
            n = struct.unpack_from("<I", self.d, params_off)[0]
            for i in range(n):
                t = struct.unpack_from("<H", self.d, params_off + 4 + i * 2)[0]
                params.append(self.type_str(t))
        return params

    # --- methods / classes ------------------------------------------------
    def methods(self):
        for i in range(self.method_ids_size):
            cidx, pidx, nidx = struct.unpack_from("<HHI", self.d, self.method_ids_off + i * 8)
            yield (self.type_str(cidx), self.string(nidx), tuple(self.proto(pidx)))

    def classes(self):
        out = []
        for i in range(self.class_defs_size):
            cidx = struct.unpack_from("<I", self.d, self.class_defs_off + i * 32)[0]
            out.append(self.type_str(cidx))
        return out

    def class_hierarchy(self):
        """{class_descriptor: superclass_descriptor} for every class in the dex."""
        out = {}
        for i in range(self.class_defs_size):
            base = self.class_defs_off + i * 32
            cidx = struct.unpack_from("<I", self.d, base)[0]
            sidx = struct.unpack_from("<I", self.d, base + 8)[0]
            out[self.type_str(cidx)] = self.type_str(sidx) if sidx != 0xFFFFFFFF else None
        return out


def inventory(path):
    dx = Dex(path)
    return sorted("%s->%s(%s)" % (c, n, ",".join(p)) for c, n, p in dx.methods())


def fingerprint(path):
    h = hashlib.sha256()
    for line in inventory(path):
        h.update(line.encode())
        h.update(b"\n")
    return h.hexdigest()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "inventory":
        print("\n".join(inventory(sys.argv[2])))
    elif cmd == "classes":
        print("\n".join(sorted(Dex(sys.argv[2]).classes())))
    elif cmd == "fingerprint":
        print(fingerprint(sys.argv[2]))
    elif cmd == "compare":
        a, b = inventory(sys.argv[2]), inventory(sys.argv[3])
        if a == b:
            print("IDENTICAL  (%d classes/methods, sha256=%s)" % (len(a), fingerprint(sys.argv[2])))
            return 0
        print("DIFFERENT")
        sa, sb = set(a), set(b)
        for x in sorted(sa - sb)[:40]:
            print("  only in A: %s" % x)
        for x in sorted(sb - sa)[:40]:
            print("  only in B: %s" % x)
        return 1
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
