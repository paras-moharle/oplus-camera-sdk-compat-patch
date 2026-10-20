#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch  (author: Paras Moharle)
#
# Camera 6.070.215+ stores the "com.oplus.picture.exif.flag" capture parameter
# as a long[], while the CameraUnit SDK shipped with the 6.020.980-era
# firmware casts it to int[]  -> ClassCastException -> no photo is ever taken.
#
# This script bind-mounts a patched copy of the SDK jar over the original.
# The original file on disk is NOT modified.
#
# IMPORTANT: the SELinux label of the SOURCE file is what the camera app will
# see.  It must stay system_file, otherwise the app (untrusted_app) cannot
# read the jar and dies with NoClassDefFoundError.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

[ -f "$SRC" ] || exit 0

chown root:root "$SRC" 2>/dev/null
chmod 644 "$SRC" 2>/dev/null
chcon u:object_r:system_file:s0 "$SRC" 2>/dev/null

mount --bind "$SRC" "$TGT" 2>/dev/null
