#!/system/bin/sh
#
# Oplus camera patch dashboard  (author: Paras Moharle)
#
# Serves a small web UI on 127.0.0.1:8787 that shows the live state of both
# camera patch modules and offers quick fixes.
#
# It never changes anything on its own: every action button calls the modules'
# OWN scripts or a plain am force-stop.
#
MODPATH="${0%/*}"
PORT=8787

find_busybox() {
  for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
           /data/adb/modules/*/busybox /system/bin/busybox; do
    [ -f "$c" ] && [ -x "$c" ] && { "$c" true >/dev/null 2>&1 && { echo "$c"; return 0; }; }
  done
  return 1
}

BB=$(find_busybox)
[ -z "$BB" ] && { echo "busybox not found - dashboard disabled" >&2; exit 0; }

mkdir -p "$MODPATH/webroot/cgi-bin"
chmod 755 "$MODPATH/webroot/cgi-bin/"*.sh 2>/dev/null

# start (or restart) the httpd - busybox httpd daemonises itself without -f
"$BB" pkill -f "httpd -p 127.0.0.1:$PORT" >/dev/null 2>&1
sleep 1
"$BB" httpd -p 127.0.0.1:$PORT -h "$MODPATH/webroot" >/dev/null 2>&1

# keep it alive: if the httpd dies (it did once), bring it back
(
  while true; do
    sleep 30
    if ! pidof httpd >/dev/null 2>&1 && ! "$BB" ps 2>/dev/null | grep -q "httpd"; then
      "$BB" httpd -p 127.0.0.1:$PORT -h "$MODPATH/webroot" >/dev/null 2>&1
    fi
  done
) >/dev/null 2>&1 &

exit 0
