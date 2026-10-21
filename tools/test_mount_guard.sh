#!/usr/bin/env bash
#
# test_mount_guard.sh - prove that the module's boot scripts can never stack
#                       mounts.
#
# WHY THIS TEST EXISTS
# --------------------
# On 2026-10-21 the camera module crashed the phone.  The watcher bound the
# same path over and over without checking whether it was already mounted:
#
#     while true; do
#         ...
#         mount --bind "$SRC" "$TGT"      # every 0.5 s, unconditionally
#         ...
#     done
#
# Each of those creates ANOTHER mount on top of the previous one.  After a
# few minutes the mount table had 6146 stacked entries and the phone died.
#
# Every mount in the module now goes through bind_once(), which checks the
# target first.  This test runs the real bind_once() logic inside a real
# mount namespace (user namespace + unshare -m) and asserts that 200 rounds
# of calls leave exactly ONE mount behind.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------ 1. behaviour
say "bind_once() must not stack mounts (real mount namespace)"

cat > "$WORK/guard.sh" <<'EOS'
#!/bin/sh
# The real bind_once() from the module, copied verbatim.
bind_once() {
  SRC="$1"; TGT="$2"; NS="$3"
  [ -e "$TGT" ] || return 0
  if [ -n "$NS" ]; then
    nsenter -t "$NS" -m -- awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
      | grep -qx "$TGT" && return 0
    nsenter -t "$NS" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null
  else
    awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
      | grep -qx "$TGT" && return 0
    mount --bind "$SRC" "$TGT" 2>/dev/null
  fi
}

mkdir -p "$T/tmp"
: > "$T/src.bin"
: > "$T/tmp/target"

# 200 rounds x 2 paths - exactly what the old watcher did every 0.5 s
i=0
while [ $i -lt 200 ]; do
  bind_once "$T/src.bin" "$T/tmp/target" ""
  bind_once "$T/src.bin" "$T/tmp/target2" ""
  i=$((i+1))
done

echo "MOUNTS=$(awk '{print $5}' /proc/self/mountinfo | grep -c "$T/tmp/target")"
EOS

OUT=$(unshare -Ur -m sh -c "T='$WORK' sh '$WORK/guard.sh'" 2>/dev/null)
COUNT=$(echo "$OUT" | sed -n 's/^MOUNTS=//p')

if [ -z "$COUNT" ]; then
  bad "could not run the test in a mount namespace (no unshare -Ur -m here)"
elif [ "$COUNT" = "1" ]; then
  ok "200 rounds x 2 paths left exactly 1 mount per path"
else
  bad "200 rounds left $COUNT mounts - the guard is broken"
fi

# ------------------------------------------------------------ 2. static
say "the real boot scripts must not contain unguarded mounts"
for f in "$REPO_DIR/ksu-module/post-fs-data.sh" "$REPO_DIR/ksu-module/service.sh"; do
  RES=$(python3 - "$f" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# comments do not count
code = "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("#"))
total = code.count("mount --bind")
# strip the bind_once() function body
m = re.search(r"^bind_once\(\) \{.*?^\}", code, re.S | re.M)
body = m.group(0) if m else ""
outside = total - body.count("mount --bind")
print(f"{total} {body.count('mount --bind')} {outside}")
PYEOF
)
  TOTAL=$(echo "$RES" | awk '{print $1}')
  IN_FUNC=$(echo "$RES" | awk '{print $2}')
  OUTSIDE=$(echo "$RES" | awk '{print $3}')
  if [ "$TOTAL" -eq "$IN_FUNC" ] && [ "$IN_FUNC" -ge 1 ] && [ "$OUTSIDE" -eq 0 ]; then
    ok "$(basename "$f"): all $TOTAL mount call(s) are inside bind_once()"
  else
    bad "$(basename "$f"): $OUTSIDE mount call(s) outside bind_once() (total $TOTAL, in bind_once $IN_FUNC)"
  fi
done

say "bind_once() is defined in both scripts"
for f in "$REPO_DIR/ksu-module/post-fs-data.sh" "$REPO_DIR/ksu-module/service.sh"; do
  if grep -q "^bind_once() {" "$f"; then
    ok "$(basename "$f") defines bind_once()"
  else
    bad "$(basename "$f") has no bind_once()"
  fi
done

say "the watcher must be able to protect itself from a stacked mount table"
for f in "$REPO_DIR/ksu-module/service.sh"; do
  if grep -q "sanity_check_mounts" "$f" && grep -q "mount_count" "$f"; then
    ok "service.sh watches the mount count and disables itself"
  else
    bad "service.sh has no self-protection against a stacked mount table"
  fi
  if grep -q 'touch "\$MODDIR/disable"' "$f"; then
    ok "service.sh can disable itself"
  else
    bad "service.sh cannot disable itself"
  fi
done

say "the module must have a hard cap on the mounts it may create"
for f in "$REPO_DIR/ksu-module/service.sh" "$REPO_DIR/ksu-module/post-fs-data.sh"; do
  if grep -q "MOUNT_CAP" "$f"; then
    ok "$(basename "$f") has a mount cap"
  else
    bad "$(basename "$f") has no mount cap"
  fi
done

say "no raw mount may survive outside bind_once()"
for f in "$REPO_DIR/ksu-module/post-fs-data.sh" "$REPO_DIR/ksu-module/service.sh"; do
  if python3 - "$f" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
src = "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("#"))
m = re.search(r"^bind_once\(\) \{.*?^\}", src, re.S | re.M)
if m:
    src = src.replace(m.group(0), "")
sys.exit(0 if "mount --bind" not in src else 1)
PYEOF
  then
    ok "$(basename "$f"): every mount goes through bind_once()"
  else
    bad "$(basename "$f"): a raw 'mount --bind' survives outside bind_once()"
  fi
done

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m*** ALL %d CHECKS PASSED ***\033[0m\n' "$PASS"
else
  printf '\033[1;31m*** %d FAILED, %d passed ***\033[0m\n' "$FAIL" "$PASS"
  exit 1
fi
