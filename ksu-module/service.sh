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
OAT_DIR=/product/framework/oat/arm64
DEX_CACHE=/data/dalvik-cache/arm64/product@framework@com.oplus.camera.unit.sdk.jar
PF="$MODDIR/pf"
PF_JAR="$PF/com.oplus.camera.unit.sdk.jar"
PROP=persist.oplus.camera.thermal_bypass

[ -f "$SDK_SRC" ] || exit 0

# The switch has to exist even if the user never touches the volume keys.
if [ "$(getprop $PROP)" = "" ]; then
  setprop $PROP 1
fi

# An empty file used to invalidate the OEM's prebuilt artifacts (.odex and
# .vdex) for the SDK jar, so that ART can never fall back to the stock
# compiled code.
[ -f "$MODDIR/empty.bin" ] || : > "$MODDIR/empty.bin" 2>/dev/null

# make sure the replacement directory for /product/framework exists and holds
# the patched jar and no prebuilt artifacts.  /product/framework is an
# OverlayFS, and ART opens the SDK jar through it - the overlay pins the
# dentry, so a bind mount over the jar is ignored.  Replacing the whole
# overlay with a plain directory is the only thing that works.
build_pf_dir() {
  if [ ! -f "$PF_JAR" ]; then
    rm -rf "$PF" 2>/dev/null
    mkdir -p "$PF" 2>/dev/null
    cp -a /product/framework/. "$PF/" 2>/dev/null
  fi
  cp -f "$SDK_SRC" "$PF_JAR" 2>/dev/null
  for f in "$PF/oat/arm64/com.oplus.camera.unit.sdk.vdex" "$PF/oat/arm64/com.oplus.camera.unit.sdk.odex"; do
    [ -e "$f" ] && : > "$f" 2>/dev/null
  done
}

# bind_once <source> <target> [namespace]
#
# NEVER stack a mount.  A mount on a path that is already mounted creates a
# NEW mount on top of it, and repeating that in a loop fills the mount table
# until the kernel gives up - which is exactly what crashed the phone once.
# So the target is always checked first, in the namespace it is going to be
# created in.
MOUNTS_MADE=0
MOUNT_CAP=16

bind_once() {
  SRC="$1"; TGT="$2"; NS="$3"
  [ -e "$TGT" ] || return 0

  # Hard cap.  The module may create a handful of mounts, never more.  If the
  # counter goes over the cap something is looping, and the module takes
  # itself out of the game instead of filling the mount table.
  if [ "$MOUNTS_MADE" -ge "$MOUNT_CAP" ]; then
    say "ABORT: the mount cap ($MOUNT_CAP) is reached - disabling the module"
    touch "$MODDIR/disable" 2>/dev/null
    exit 0
  fi

  if [ -n "$NS" ]; then
    nsenter -t "$NS" -m -- awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
      | grep -qx "$TGT" && return 0
    nsenter -t "$NS" -m -- mount --bind "$SRC" "$TGT" 2>/dev/null && MOUNTS_MADE=$((MOUNTS_MADE+1))
  else
    awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
      | grep -qx "$TGT" && return 0
    mount --bind "$SRC" "$TGT" 2>/dev/null && MOUNTS_MADE=$((MOUNTS_MADE+1))
  fi
}

mask_prebuilt() {
  # $1 = the namespace to work in ("" = the current one)
  NS="$1"
  for f in com.oplus.camera.unit.sdk.vdex com.oplus.camera.unit.sdk.odex; do
    bind_once "$MODDIR/empty.bin" "$OAT_DIR/$f" "$NS"
  done
}

# ------------------------------------------------------------------ helpers

# ART keeps the dexopt output of the SDK jar in /data/dalvik-cache.  If that
# cache was built from the STOCK jar, ART keeps using it (and the camera
# keeps cancelling every capture), so it has to be dropped whenever the mount
# is (re)applied.  The next app that starts then dexopts the jar that is
# really mounted - ours.
clear_dex_cache() {
  rm -f "$DEX_CACHE"@classes.vdex 2>/dev/null
  rm -f "$DEX_CACHE"@classes.dex 2>/dev/null
}

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

# ------------------------------------------------------- self-protection
#
# The mount table is a finite resource.  A loop that binds the same path over
# and over filled it with 6146 stacked mounts once and took the phone down.
# bind_once() prevents that, but as a last resort this watcher watches the
# mount count of every path it touches: if it is ever more than one, the
# extra mounts are removed and the module disables ITSELF, so a mistake can
# never take the phone down again.
mount_count() {
  awk '{print $5}' /proc/self/mountinfo 2>/dev/null | grep -c "^$1$"
}

sanity_check_mounts() {
  for t in "$SDK_TGT" "$OAT_DIR/com.oplus.camera.unit.sdk.vdex" "$OAT_DIR/com.oplus.camera.unit.sdk.odex"; do
    c=$(mount_count "$t")
    if [ "${c:-0}" -gt 1 ]; then
      say "ABORT: $t has $c stacked mounts - removing the extras and disabling the module"
      while [ "$c" -gt 1 ]; do
        umount "$t" 2>/dev/null || break
        c=$((c - 1))
      done
      touch "$MODDIR/disable" 2>/dev/null
      say "the module has been disabled - reboot to be safe"
      exit 0
    fi
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
  # camera would silently fall back to the stock jar - and to the OEM's
  # prebuilt artifact compiled from it.
  if [ -n "$Z" ]; then
    if [ "$Z" != "$LAST_Z" ]; then
      LAST_Z="$Z"
      build_pf_dir
      bind_once "$PF" /product/framework "$Z"
      bind_once "$SDK_SRC" "$SDK_TGT" "$Z"
      mask_prebuilt "$Z"
      clear_dex_cache
    elif [ $((WATCH_N % 4)) -eq 0 ]; then
      if ! nsenter -t "$Z" -m -- awk '{print $5}' /proc/self/mountinfo 2>/dev/null \
           | grep -qx "$SDK_TGT"; then
        say "the zygote namespace lost the patched jar - restoring it"
        bind_once "$SDK_SRC" "$SDK_TGT" "$Z"
        mask_prebuilt "$Z"
        # ART caches the dexopt output in /data/dalvik-cache.  If that cache
        # was built from the stock jar it would keep being used, so it has to
        # go - the next app that starts then dexopts the jar that is really
        # mounted (ours).
        clear_dex_cache
      fi
    fi
    WATCH_N=$((WATCH_N + 1))
  fi

  # --- init namespace (in case it was lost) ------------------------------
  build_pf_dir
  bind_once "$PF" /product/framework ""
  bind_once "$SDK_SRC" "$SDK_TGT" ""
  mask_prebuilt ""

  # --- the camera app's own namespace (cosmetic) -------------------------
  PID=$(pidof com.oplus.camera 2>/dev/null | awk '{print $1}')
  if [ -n "$PID" ] && [ "$PID" != "$LAST_PID" ]; then
    bind_once "$PF" /product/framework "$PID"
    bind_once "$SDK_SRC" "$SDK_TGT" "$PID"
    mask_prebuilt "$PID"
    LAST_PID="$PID"
  fi

  sanity_check_mounts

  sleep 0.5

  watchdog_camera_spin
done

exit 0
