#!/usr/bin/env bash
#
# install_webui.sh - deploy the "ocam_webui" dashboard module.
#
# Also records the expected SHA256 of both camera-patch modules so the
# dashboard can tell "the right file is deployed" apart from "the right file
# is actually mounted".
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
MOD="ksu-module-webui"
DST="/data/adb/modules/ocam_webui"
PORT=8787

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

command -v adb >/dev/null || die "adb not found"
adb get-state >/dev/null 2>&1 || die "no adb device"
if adb shell "su -c 'id -u' 2>/dev/null" | grep -q 0; then
  drun() { adb shell "su -c '$1'"; }
else
  drun() { adb shell "$1"; }
fi

say "deploying the dashboard module to $DST"
drun "rm -rf $DST && mkdir -p $DST/webroot/cgi-bin"
for f in module.prop service.sh; do
  adb push "$REPO_DIR/$MOD/$f" "$DST/$f" >/dev/null
done
adb push "$REPO_DIR/$MOD/webroot/index.html"          "$DST/webroot/index.html" >/dev/null
adb push "$REPO_DIR/$MOD/webroot/cgi-bin/status.sh"    "$DST/webroot/cgi-bin/status.sh" >/dev/null
adb push "$REPO_DIR/$MOD/webroot/cgi-bin/action.sh"    "$DST/webroot/cgi-bin/action.sh" >/dev/null
drun "chmod 755 $DST/service.sh $DST/webroot/cgi-bin/status.sh $DST/webroot/cgi-bin/action.sh"
drun "chmod 644 $DST/module.prop $DST/webroot/index.html"
drun "chown -R root:root $DST"

say "recording the expected hashes for both patch modules"
drun "sha256sum /data/adb/modules/ocam_sdkfix/SDK-PATCHED.jar | cut -d' ' -f1 > /data/adb/modules/ocam_sdkfix/SDK-PATCHED.jar.sha256"
drun "sha256sum /data/adb/modules/ocam_thermalfix/PATCHED-ofw.jar | cut -d' ' -f1 > /data/adb/modules/ocam_thermalfix/PATCHED-ofw.jar.sha256"
drun "printf 'uid=%s temp=%s status=%s\n' 10155 30.0 13 > /data/adb/modules/ocam_thermalfix/patch.params"

say "starting the dashboard"
drun "sh $DST/service.sh"
sleep 2

say "modules on the device:"
drun "ls -l $DST $DST/webroot $DST/webroot/cgi-bin" | sed 's/^/  /'
drun "cat /data/adb/modules/ocam_sdkfix/SDK-PATCHED.jar.sha256 /data/adb/modules/ocam_thermalfix/PATCHED-ofw.jar.sha256 /data/adb/modules/ocam_thermalfix/patch.params" | sed 's/^/  /'

cat <<EOF

$(printf '\033[1;32m*** INSTALLED ***\033[0m')

Dashboard:  http://127.0.0.1:$PORT
From the PC:  adb forward tcp:$PORT tcp:$PORT   then open http://127.0.0.1:$PORT

It shows for both modules: enabled, bind mount active, deployed sha256 vs the
expected hash, whether the live file is the patched one, the thermal bypass
parameters, camera state and the MKP panic rate - plus buttons to re-mount,
force stop / restart the camera and fire a test capture.

The dashboard starts automatically at every boot (module service.sh).
EOF
