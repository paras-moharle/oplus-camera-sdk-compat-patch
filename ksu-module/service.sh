#!/system/bin/sh
#
# Oplus camera fix - service  (author: Paras Moharle)
#
# Three jobs:
#
#  1. Close the boot-time race for the SDK jar.  post-fs-data.sh mounts the
#     patched jar into the zygote's mount namespace, but the zygote does not
#     always start after post-fs-data (this phone runs a MediaTek MKP
#     kernel-panic storm, load average 20+, and the zygote is sometimes
#     early).  This watcher mounts it as soon as the zygote is there.
#
#  2. The volume key toggle for the thermal bypass.
#
#        hold volume-down for 2 s   ->  toggle the thermal bypass
#        hold volume-up   for 2 s   ->  show the current state
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
# * Only "mount --bind", "setprop" and "getevent" are used.  No chcon /
#   setfattr / setenforce: the MKP kernel-integrity module panics the kernel
#   if the SELinux state changes while the system boots.
# * Every failure path exits 0.  This script can never fail a boot.
# * It never restarts or kills any app.

MODDIR=/data/adb/modules/ocam_camfix
SDK_SRC="$MODDIR/SDK-PATCHED.jar"
SDK_TGT=/product/framework/com.oplus.camera.unit.sdk.jar
PROP=persist.oplus.camera.thermal_bypass

[ -f "$SDK_SRC" ] || exit 0

# The switch has to exist even if the user never touches the volume keys.
if [ "$(getprop $PROP)" = "" ]; then
  setprop $PROP 1
fi

# ------------------------------------------------------------------ helpers

now_ms() {
  # /proc/uptime has centisecond resolution - plenty for a 2 s threshold
  awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null
}

say() {
  log -t ocam_camfix "$*"
}

# Post a short notification so the user sees what happened.  Falls back to
# the log if the notification service refuses the post.
notify() {
  TITLE="$1"; TEXT="$2"
  say "$TITLE: $TEXT"
  cmd notification post "$TITLE" "$TEXT" >/dev/null 2>&1 || true
}

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
  if [ "$S" = "0" ]; then
    NEW=1
  else
    NEW=0
  fi
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
#   0001 0073 00000001   (EV_KEY, KEY_VOLUMEDOWN, DOWN)
#
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

LAST_Z=""
LAST_PID=""
WATCH_N=0

while true; do
  # --- the zygote: the important one -------------------------------------
  Z=""
  for p in $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
    Z="$p"
    break
  done

  # The mount is checked, not just tracked by PID: the zygote namespace can
  # lose the mount (a late `umount`, a remount of /product, ...) and the
  # camera would silently fall back to the stock jar.
  if [ -n "$Z" ]; then
    if [ "$Z" != "$LAST_Z" ]; then
      LAST_Z="$Z"
      nsenter -t "$Z" -m -- mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
    elif [ $((WATCH_N % 20)) -eq 0 ]; then
      if ! nsenter -t "$Z" -m -- awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
           | grep -qx "$SDK_TGT"; then
        say "the zygote namespace lost the patched jar - restoring it"
        nsenter -t "$Z" -m -- mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
      fi
    fi
    WATCH_N=$((WATCH_N + 1))
  fi

  # --- init namespace (in case it was lost) ------------------------------
  if ! awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -qx "$SDK_TGT"; then
    mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
  fi

  # --- the camera app's own namespace (cosmetic) -------------------------
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  if [ -n "$PID" ] && [ "$PID" != "$LAST_PID" ]; then
    nsenter -t "$PID" -m -- mount --bind "$SDK_SRC" "$SDK_TGT" 2>/dev/null
    LAST_PID="$PID"
  fi

  sleep 0.5

  watchdog_camera_spin
done

exit 0
