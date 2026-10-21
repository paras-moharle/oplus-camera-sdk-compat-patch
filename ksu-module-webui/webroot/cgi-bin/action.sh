#!/system/bin/sh
#
# action.sh - CGI endpoint: performs a quick action.
#
#   ?a=remount      re-apply both bind mounts (runs the modules' own scripts)
#   ?a=stop         force stop the camera
#   ?a=start        force stop + relaunch the camera
#   ?a=shutter      fire a shutter press
#   ?a=restart_http restart the dashboard itself
#
echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo ""

ACT=$(printf '%s' "${QUERY_STRING:-}" | sed 's/.*a=\([a-z_]*\).*/\1/')
SDK_DIR=/data/adb/modules/ocam_sdkfix
TH_DIR=/data/adb/modules/ocam_thermalfix
MSG=""

case "$ACT" in
  remount)
    # run each module's own boot script - it has the guards (hash, size, label)
    sh "$SDK_DIR/post-fs-data.sh" >/dev/null 2>&1
    sh "$TH_DIR/post-fs-data.sh" >/dev/null 2>&1
    MSG="re-applied both bind mounts"
    ;;
  stop)
    am force-stop com.oplus.camera >/dev/null 2>&1
    MSG="camera force stopped"
    ;;
  start)
    am force-stop com.oplus.camera >/dev/null 2>&1
    sleep 1
    monkey -p com.oplus.camera -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    MSG="camera restarted"
    ;;
  shutter)
    input tap 619 2253 >/dev/null 2>&1
    MSG="shutter fired"
    ;;
  *)
    MSG="unknown action"
    ;;
esac

printf '{"action":"%s","msg":"%s"}\n' "$ACT" "$MSG"
