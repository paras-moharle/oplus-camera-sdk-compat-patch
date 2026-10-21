#!/system/bin/sh
#
# status.sh - CGI endpoint: returns the live state of everything as JSON.
#
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

SDK_DIR=/data/adb/modules/ocam_sdkfix
TH_DIR=/data/adb/modules/ocam_thermalfix
SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
TH_TGT=/system/framework/oplus-framework.jar

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
mounted() { awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$1" && echo true || echo false; }

# ---- module 1: SDK compat patch -----------------------------------------
SDK_EXPECT=$(cat "$SDK_DIR/SDK-PATCHED.jar.sha256" 2>/dev/null)
SDK_ACTUAL=$(sha "$SDK_DIR/SDK-PATCHED.jar")
SDK_ONDISK=$(sha "$SDK_TGT")
[ -z "$SDK_EXPECT" ] && SDK_EXPECT=$(sha "$SDK_DIR/SDK-PATCHED.jar")
SDK_ENABLED=false; [ -f "$SDK_DIR/disable" ] || SDK_ENABLED=true
SDK_MOUNT=$(mounted "$SDK_TGT")

# ---- module 2: thermal bypass ------------------------------------------
TH_EXPECT=$(cat "$TH_DIR/PATCHED-ofw.jar.sha256" 2>/dev/null)
TH_ACTUAL=$(sha "$TH_DIR/PATCHED-ofw.jar")
TH_ONDISK=$(sha "$TH_TGT")
TH_ENABLED=false; [ -f "$TH_DIR/disable" ] || TH_ENABLED=true
TH_MOUNT=$(mounted "$TH_TGT")
TH_PARAMS=$(cat "$TH_DIR/patch.params" 2>/dev/null | tr '\n' ' ')

# ---- camera --------------------------------------------------------------
CAM_VER=$(dumpsys package com.oplus.camera 2>/dev/null | grep -m1 versionName | sed 's/.*=//' | tr -d '\r ')
CAM_PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
CAM_CRASHES=0
for f in $(ls -t /data/system/dropbox/ 2>/dev/null | head -60); do
  grep -qm1 "^Process: com.oplus.camera" "/data/system/dropbox/$f" 2>/dev/null && CAM_CRASHES=$((CAM_CRASHES+1))
done

# ---- thermal -------------------------------------------------------------
HORA_T=$(dumpsys horae 2>/dev/null | grep -m1 '^Temp:' | sed 's/[^0-9.]//g')
SKIN_T=$(dumpsys thermalservice 2>/dev/null | grep -m1 mName=SKIN | grep -oE 'mValue=[0-9.]+' | cut -d= -f2)
THERM_STATUS=$(dumpsys thermalservice 2>/dev/null | grep -m1 'Thermal Status' | grep -oE '[0-9]+$' | head -1)

# ---- MKP panic rate ------------------------------------------------------
P1=$(dmesg 2>/dev/null | grep -c do_policy_action_panic)
sleep 3
P2=$(dmesg 2>/dev/null | grep -c do_policy_action_panic)

cat <<JSON
{
  "sdk": {
    "enabled": $SDK_ENABLED,
    "mounted": $SDK_MOUNT,
    "expect": "$(esc "$SDK_EXPECT")",
    "deployed": "$(esc "$SDK_ACTUAL")",
    "ondisk": "$(esc "$SDK_ONDISK")",
    "hash_ok": $( [ -n "$SDK_EXPECT" ] && [ "$SDK_EXPECT" = "$SDK_ACTUAL" ] && echo true || echo false ),
    "live_ok": $( [ "$SDK_ONDISK" = "$SDK_ACTUAL" ] && echo true || echo false )
  },
  "thermal": {
    "enabled": $TH_ENABLED,
    "mounted": $TH_MOUNT,
    "expect": "$(esc "$TH_EXPECT")",
    "deployed": "$(esc "$TH_ACTUAL")",
    "ondisk": "$(esc "$TH_ONDISK")",
    "hash_ok": $( [ -n "$TH_EXPECT" ] && [ "$TH_EXPECT" = "$TH_ACTUAL" ] && echo true || echo false ),
    "live_ok": $( [ "$TH_ONDISK" = "$TH_ACTUAL" ] && echo true || echo false ),
    "params": "$(esc "$TH_PARAMS")"
  },
  "camera": {
    "version": "$(esc "$CAM_VER")",
    "pid": "$(esc "$CAM_PID")",
    "running": $( [ -n "$CAM_PID" ] && echo true || echo false ),
    "crashes": $CAM_CRASHES
  },
  "device": {
    "hora_temp": "$(esc "$HORA_T")",
    "skin_temp": "$(esc "$SKIN_T")",
    "thermal_status": "$(esc "$THERM_STATUS")",
    "mkp_panics_per_min": $(( (P2-P1)*20 ))
  }
}
JSON
