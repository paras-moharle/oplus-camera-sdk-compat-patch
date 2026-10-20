#!/system/bin/sh
#
# Oplus CameraUnit SDK compat patch  (author: Paras Moharle)
#
# Camera 6.070.215+ stores the "com.oplus.picture.exif.flag" capture parameter
# as a long[], while the CameraUnit SDK shipped with 6.020.980-era firmware
# casts it to int[]  -> ClassCastException -> no photo is ever taken.
#
# This script bind-mounts a patched copy of the SDK jar over the original.
# The original file on disk is NOT modified.
#
# SAFETY - IMPORTANT
# -----------------
# Do NOT run "chcon"/"setfattr" here.  MediaTek's MKP kernel-integrity module
# hashes the SELinux policy/state and panics the kernel (-> kernel panic, boot
# loop) as soon as any SELinux label on the device is changed at boot time.
# The module directory is already labelled "adb_data_file", which the camera
# app and the camera HAL can both read, so NO label change is required.
# Only "mount --bind" is performed here; ownership/permissions are set once,
# at install time, by install.sh.

MODDIR=/data/adb/modules/ocam_sdkfix
SRC="$MODDIR/SDK-PATCHED.jar"
TGT=/product/framework/com.oplus.camera.unit.sdk.jar

[ -f "$SRC" ] || exit 0

mount --bind "$SRC" "$TGT" 2>/dev/null
