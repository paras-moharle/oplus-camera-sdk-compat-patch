#!/system/bin/sh
#
# Oplus camera fix - service  (author: Paras Moharle)
#
# Jobs:
#
#  1. Keep the SDK redirect alive and PROVE it is alive.
#
#     The camera loads com.oplus.camera.unit.sdk.jar from /product/framework.
#     The module redirects that path in the kernel (NoMount "nm" rules, see
#     post-fs-data.sh), so every process - in every mount namespace - opens
#     the patched jar.  This watcher checks the redirect every 10 seconds:
#
#         stat /product/framework/com.oplus.camera.unit.sdk.jar
#
#     must report OUR size, and the OEM's prebuilt .vdex must report 0 bytes.
#     If it does not (rule lost, NoMount reloaded, metamodule updated, jar
#     replaced), the rules are re-applied at once.
#
#     If it cannot be repaired, the user gets a notification - the camera
#     must never silently fall back to the stock SDK and cancel captures.
#
#  2. The volume key toggle for the thermal bypass.
#
#         hold volume-down for 2 s   ->  toggle the thermal bypass
#         hold volume-up   for 2 s   ->  show the current state
#
#     The bypass is a system property that the patched
#     OplusHoraeThermalHelper reads on every call, so the change is effective
#     immediately - no reboot, no remount.  The property is persist.*, so the
#     choice survives a reboot.
#
#     A short press still changes the volume as usual: the raw key events are
#     only *read* here, never consumed.
#
#  3. Watchdog: if the camera's private-log writer gets stuck in a retry loop
#     (it cannot write /data/vendor because of the SELinux policy), it pegs a
#     CPU core and eventually gets the camera process killed.  If that is
#     detected, the private log is switched off so the camera survives.
#
# SAFETY
# ------
# * The module creates ONE bind mount (the bootclasspath thermal jar), through
#   an inode-checked bind_once() with a hard cap.  There is no mount loop.
# * Only "mount --bind", "setprop" and "getevent" are used.  No chcon /
#   setfattr / setenforce: the MKP kernel-integrity module panics the kernel
#   if the SELinux state changes while the system boots.
# * Every failure path exits 0.  This script can never fail a boot.
# * It never touches an app, with one exception: if the redirect really was
#   lost while the camera was running (that process keeps the stock classes
#   and would ignore every shutter press), the camera is force-stopped so the
#   next launch loads the patched SDK again.  The user is told.

PATH=/system/bin:/system/xbin:/vendor/bin:/bin:/sbin:$PATH
export PATH

MODDIR=/data/adb/modules/ocam_camfix
SDK_SRC="$MODDIR/SDK-PATCHED.jar"
SDK_REDIR="$MODDIR/product/framework/com.oplus.camera.unit.sdk.jar"
OAT_REDIR="$MODDIR/product/framework/oat/arm64"
SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
OAT_TGT=/product/framework/oat/arm64
OFW_SRC="$MODDIR/PATCHED-ofw.jar"
OFW_TGT=/system/framework/oplus-framework.jar
DEX_CACHE=/data/dalvik-cache/arm64/product@framework@com.oplus.camera.unit.sdk.jar
PROP=persist.oplus.camera.thermal_bypass
LOG="$MODDIR/status.txt"

[ -f "$SDK_SRC" ] || exit 0

# The switch has to exist even if the user never touches the volume keys.
if [ "$(getprop $PROP)" = "" ]; then
  setprop $PROP 1
fi

SDK_SZ=$(stat -c %s "$SDK_SRC" 2>/dev/null)
[ -n "$SDK_SZ" ] || exit 0

# Record the PID so install.sh / uninstall.sh / boot-completed.sh can find and
# stop this watcher.  Pattern-matching ("pkill -f .../service.sh") is not used:
# it would also match the shell that is running the pkill itself.
echo $$ > "$MODDIR/service.pid" 2>/dev/null

say() { log -t ocam_camfix "$*"; }
record() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# Post a short notification so the user sees what happened.  Falls back to
# the log if the notification service refuses the post.
notify() {
  say "$1: $2"
  cmd notification post "$1" "$2" >/dev/null 2>&1 || true
}

now_ms() {
  # /proc/uptime has centisecond resolution - plenty for a 2 s threshold
  awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null
}

# ------------------------------------------------------------------- redirect
NM=""
for c in "$MODDIR/../nomount/bin/nm" /data/adb/ksu/bin/nm /data/adb/ap/bin/nm nm; do
  if command -v "$c" >/dev/null 2>&1; then NM="$c"; break; fi
done

add_rules() {
  [ -n "$NM" ] || return 1
  "$NM" rule add "$SDK_TGT" "$SDK_REDIR" >/dev/null 2>&1 || return 1
  for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
    "$NM" rule add "$OAT_TGT/$f" "$OAT_REDIR/$f" >/dev/null 2>&1 || return 1
  done
  return 0
}

# Never leave the OEM prebuilt vdex masked while the jar is still the stock one:
# ART then trusts a zero-length dex file for the stock jar, fails to resolve
# every SDK class and the camera dies at launch with NoClassDefFoundError
# (CameraAdapterUtils).  A broken-but-open camera is better than a crash, and
# the next add_rules() puts the real jar in place first.
demask_if_inconsistent() {
  [ -n "$NM" ] || return 0
  SZ=$(stat -Lc %s "$SDK_TGT" 2>/dev/null)
  [ "$SZ" = "$SDK_SZ" ] && return 0
  VZ=$(stat -Lc %s "$OAT_TGT/com.oplus.camera.unit.sdk.vdex" 2>/dev/null)
  [ "$VZ" = "0" ] || return 0
  say "inconsistent state (stock jar + masked vdex) - unmasking the OEM dex first"
  for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
    "$NM" rule del "$OAT_TGT/$f" >/dev/null 2>&1 || true
  done
  record "service: unmasked the OEM vdex/odex to avoid a camera crash"
}

# The redirect is in effect when the OEM path reports our jar and the OEM
# prebuilt vdex is hidden behind a zero-length file.
redirect_ok() {
  SZ=$(stat -Lc %s "$SDK_TGT" 2>/dev/null)
  VZ=$(stat -Lc %s "$OAT_TGT/com.oplus.camera.unit.sdk.vdex" 2>/dev/null)
  [ "$SZ" = "$SDK_SZ" ] && [ "$VZ" = "0" ]
}

# Drop a dalvik-cache entry that may have been built from the stock jar.
clear_dex_cache() {
  rm -f "$DEX_CACHE"@classes.vdex 2>/dev/null
  rm -f "$DEX_CACHE"@classes.dex 2>/dev/null
}

# The redirect target must still be the patched jar.  A truncated file (disk
# error, interrupted copy, an OTA that rewrote the module dir) would be
# redirected to just as happily as the good one, so check and repair it.
target_ok() {
  SZ=$(stat -c %s "$SDK_REDIR" 2>/dev/null)
  [ "$SZ" = "$SDK_SZ" ] && return 0
  cp -f "$SDK_SRC" "$SDK_REDIR" 2>/dev/null
  [ "$(stat -c %s "$SDK_REDIR" 2>/dev/null)" = "$SDK_SZ" ]
}

# Stop the camera when it may have loaded the STOCK sdk.  ART extracts the dex
# once, at process start: a process that began while the redirect was gone
# keeps the broken classes until it is restarted, and its shutter does
# nothing.  Restarting is the only recovery, and it is done only when the
# redirect really was lost while the app was running.
recover_camera() {
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  [ -n "$PID" ] || return 0
  am force-stop com.oplus.camera >/dev/null 2>&1 || return 0
  record "service: camera was running with a broken redirect - force-stopped so it reloads the patched SDK"
  notify "Oplus camera fix" "The camera fix was interrupted and has been restored. Reopen the camera."
}

# ------------------------------------------------------------- thermal mount
MOUNTS_MADE=0
MOUNT_CAP=4

already_ours() {
  A=$(stat -Lc "%d:%i" "$1" 2>/dev/null)
  B=$(stat -Lc "%d:%i" "$2" 2>/dev/null)
  [ -n "$A" ] && [ -n "$B" ] && [ "$A" = "$B" ]
}

bind_once() {
  [ -e "$2" ] || return 0
  already_ours "$1" "$2" && return 0
  [ "$MOUNTS_MADE" -ge "$MOUNT_CAP" ] && return 0
  mount --bind "$1" "$2" 2>/dev/null && MOUNTS_MADE=$((MOUNTS_MADE + 1))
}

# Keep the bootclasspath mount in place even if something unmounted it: the
# zygote already has the patched class, but cameraserver / a restarted media
# stack may open the jar again.
keep_thermal_mount() {
  [ -f "$OFW_SRC" ] || return 0
  bind_once "$OFW_SRC" "$OFW_TGT"
}

# ------------------------------------------------------------------ volume keys
thermal_state() {
  S=$(getprop $PROP)
  [ "$S" = "0" ] && S=1 || S=0
  if [ "$S" = "1" ]; then
    echo "ON (the camera sees 30 degC instead of the real skin temperature)"
  else
    echo "OFF (the camera sees the real skin temperature)"
  fi
}

toggle_thermal() {
  S=$(getprop $PROP)
  if [ "$S" = "0" ]; then NEW=1; else NEW=0; fi
  setprop $PROP "$NEW"
  if [ "$NEW" = "1" ]; then
    notify "Oplus camera fix" "Thermal bypass ON - the camera no longer waits for the phone to cool down"
  else
    notify "Oplus camera fix" "Thermal bypass OFF - the camera sees the real temperature again"
  fi
}

show_thermal() {
  T=$(dumpsys horae 2>/dev/null | sed -n 's/.*Temp:\([0-9.]*\).*/\1/p' | head -1)
  [ -n "$T" ] || T="?"
  notify "Oplus camera fix" "Thermal bypass: $(thermal_state)  Real skin temperature: ${T} degC"
}

# Handle one raw key event.
#
#   EV_KEY            = 0001
#   KEY_VOLUMEDOWN    = 0073 (115)
#   KEY_VOLUMEUP      = 0074 (116)
#   value 1 = down, 0 = up, 2 = auto-repeat
#
# The events are only READ, never grabbed, so the volume still works normally.
# getevent prints them in one of a few shapes depending on the build and the
# flags, so all of them are accepted:
#
#   /dev/input/event7: 0001 0073 00000001
#   0001 0073 00000001
#   EV_KEY KEY_VOLUMEDOWN DOWN
handle_key() {
  LINE="$1"
  case "$LINE" in /dev/input/*) LINE="${LINE#*: }" ;; esac

  F1="${LINE%% *}"; R="${LINE#* }"; F2="${R%% *}"; R="${R#* }"; F3="${R%% *}"

  if [ "$F1" = "0001" ]; then
    case "$F2" in
      0073) KEY=down ;;
      0074) KEY=up ;;
      *) return 0 ;;
    esac
    case "$F3" in
      00000001) PRESS=1 ;;
      00000000) PRESS=0 ;;
      *) return 0 ;;
    esac
  else
    # label-only shape: "EV_KEY KEY_VOLUMEDOWN DOWN"
    case "$LINE" in
      *KEY_VOLUMEDOWN*DOWN*) KEY=down; PRESS=1 ;;
      *KEY_VOLUMEUP*DOWN*)   KEY=up;   PRESS=1 ;;
      *KEY_VOLUMEDOWN*UP*)   KEY=down; PRESS=0 ;;
      *KEY_VOLUMEUP*UP*)     KEY=up;   PRESS=0 ;;
      *) return 0 ;;
    esac
  fi

  if [ "$PRESS" = "1" ]; then
    DOWN_KEY="$KEY"
    DOWN_TS=$(now_ms)
    return 0
  fi

  # released
  if [ "$KEY" = "$DOWN_KEY" ] && [ -n "$DOWN_TS" ]; then
    DUR=$(( $(now_ms) - DOWN_TS ))
    say "key $KEY released after ${DUR} ms"
    if [ "$DUR" -ge 2000 ]; then
      if [ "$KEY" = "down" ]; then
        toggle_thermal
      else
        show_thermal
      fi
    fi
  fi
  DOWN_KEY=""
  DOWN_TS=""
  return 0
}

DOWN_KEY=""
DOWN_TS=""

key_watch() {
  getevent -q 2>/dev/null | while read -r LINE; do
    case "$LINE" in
      *KEY_VOLUME*|*0073*|*0074*) handle_key "$LINE" ;;
    esac
  done
}

# ----------------------------------------------------------------- watchdog
SPIN_ACC=0
SPIN_N=0
SPIN_PREV=""

# Measured on this device (CPU ticks per 0.5 s sample):
#   idle                    0 - 1
#   during a capture       21 - 78, for ~6 s
#   during the writer spin ~50, continuously, for minutes
#
# A capture and the spin look the same per sample, so the difference is the
# DURATION: the spin never lets up.  The watchdog therefore only fires when
# the camera has been continuously busy for 30 s and has burned more than 30
# CPU-seconds in that time (i.e. a full core, continuously).
watchdog_camera_spin() {
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  [ -n "$PID" ] || return 0
  [ -r "/proc/$PID/stat" ] || return 0
  CUR=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null)
  [ -n "$CUR" ] || return 0
  if [ -n "$SPIN_PREV" ]; then
    D=$((CUR - SPIN_PREV))
    if [ "$D" -ge 30 ]; then
      SPIN_ACC=$((SPIN_ACC + D))
      SPIN_N=$((SPIN_N + 1))
    else
      SPIN_ACC=0
      SPIN_N=0
    fi
  fi
  SPIN_PREV="$CUR"
  # 60 samples = 30 s of continuous busy, 1800 ticks = 30 CPU-seconds
  if [ "$SPIN_N" -ge 60 ] && [ "$SPIN_ACC" -ge 1800 ]; then
    setprop persist.sys.camera.private.log.enable false
    say "the camera is spinning - the private log has been switched off"
    SPIN_ACC=0
    SPIN_N=0
  fi
}

# --------------------------------------------------------------------- main
key_watch &
KEYPID=$!
echo "$KEYPID" > "$MODDIR/service.keypid" 2>/dev/null

# Kill the key reader as well, or it would stay behind as an orphan and keep
# reading /dev/input after this watcher is stopped.
trap 'kill $KEYPID $(cat /proc/$KEYPID/task/$KEYPID/children 2>/dev/null) 2>/dev/null; rm -f "$MODDIR/service.pid" "$MODDIR/service.keypid" 2>/dev/null; exit 0' TERM INT

# The first check happens immediately: post-fs-data may have run before
# NoMount finished loading.  For the first minute the check runs on EVERY
# iteration (twice a second), so a rule that is lost during boot is caught
# before the user can open the camera.
add_rules
target_ok
if redirect_ok; then
  record "service: SDK redirect active ($(stat -Lc %s "$SDK_TGT") bytes)"
else
  record "service: SDK redirect NOT effective yet (nm=$NM)"
fi
clear_dex_cache
keep_thermal_mount

FAIL_N=0
LAST_NOTIFY=0
N=0
WAS_OK=1

while true; do
  # the redirect: cheap stat twice a second during boot, then every 10 s
  if [ "$N" -lt 120 ] || [ $((N % 20)) -eq 0 ]; then
    if ! redirect_ok; then
      say "the SDK redirect was lost - re-applying"
      WAS_OK=0
      target_ok
      demask_if_inconsistent
      add_rules
      clear_dex_cache
      if redirect_ok; then
        record "service: SDK redirect restored"
        # A camera process that started while the redirect was gone loaded the
        # stock classes and would ignore every shutter press.  Restart it.
        recover_camera
        FAIL_N=0
      else
        FAIL_N=$((FAIL_N + 1))
        record "service: SDK redirect still broken (attempt $FAIL_N, nm=$NM)"
        # tell the user, at most once every 10 minutes
        NOW=$(date +%s 2>/dev/null)
        [ -n "$NOW" ] || NOW=0
        if [ $((NOW - LAST_NOTIFY)) -ge 600 ]; then
          LAST_NOTIFY=$NOW
          if [ -z "$NM" ]; then
            notify "Oplus camera fix" "Camera fix INACTIVE: the NoMount (nm) metamodule is missing. The camera will cancel captures."
          else
            notify "Oplus camera fix" "Camera fix INACTIVE: the patched SDK is not being loaded. See /data/adb/modules/ocam_camfix/status.txt"
          fi
        fi
      fi
    else
      FAIL_N=0
      if [ "$WAS_OK" = "0" ]; then
        WAS_OK=1
        record "service: redirect healthy again"
      fi
    fi
    keep_thermal_mount
  fi

  N=$((N + 1))
  sleep 0.5
  watchdog_camera_spin
done

exit 0
