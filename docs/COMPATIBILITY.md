# Compatibility matrix

**Author:** Paras Moharle

---

## 1. Test device

| Property | Value |
|---|---|
| Brand / model | **OnePlus Nord 3** (`CPH2491`, device codename `OP556FL1`) |
| SoC | Qualcomm Snapdragon 782G (MTK camera HAL 3.0) |
| Rear camera | 50 MP + 8 MP (ultrawide) + 2 MP (macro) — `ro.vendor.oplus.camera.backCamSize = 50MP+8MP+2MP` |
| Front camera | 16 MP |
| RAM / storage | 8 GB / 128 GB (typical SKU) |
| Android | **16** (SDK 36) |
| ColorOS / OxygenOS | **16** — `16.0.5.1301(EX01)`, build `BP2A.250605.015` |
| Build fingerprint | `OnePlus/OP556FL1:16/BP2A.250605.015/…:user/release-keys` |
| Kernel | `5.4.250-android13-8` (MediaTek MKP integrity module enabled) |
| Root | KernelSU (su available, `untrusted_app` restrictions enforced) |
| SELinux | **Enforcing** (MKP panics the kernel if set to permissive) |
| Stock camera app | `com.oplus.camera` **6.020.980** (`/product/app/OplusCamera/OplusCamera.apk`) |
| CameraUnit SDK on device | `/product/framework/com.oplus.camera.unit.sdk.jar` (6.020.980-era) + `…adapter.jar` |
| `com.oplus.aiunit` | 16.1.32 (system) |

---

## 2. Build matrix

| Camera APK | CameraUnit SDK on device | Result |
|---|---|---|
| 6.020.980 | 6.020.980-era | ✅ works (stock) |
| 6.070.215 | 6.020.980-era | ❌ **broken** — this repo's target |
| 6.070.215 | 6.070.215-era | ✅ works (no patch needed) |
| 6.020.980 | 6.070.215-era | ⚠️ may break in the opposite direction |
| any | unknown | run `tools/analyze_sdk_skew.py` to check |

---

## 3. Is the patch hardware dependent?

**No.** The patch is a Java type-compatibility fix in the CameraUnit SDK. It
touches no HAL, no ISP, no sensor, no tuning data, no camera parameter
plumbing.

| Layer | Hardware dependent? | Notes |
|---|---|---|
| `long[]` vs `int[]` mismatch | **No** | Java type contract between two *firmware* components |
| `ProducerImpl.takePicture()` | **No** | shared by photo / portrait / selfie / night |
| `CameraRequestTag.mExif` truncation | **No** | 32-bit bitmask in both contracts |
| Preview + video | **No** | never touched by the bug |
| Exposure / 3A / HDR / tone mapping | **No** | untouched, measured identical |
| Which modes are affected | **No** | every still-capture mode fails identically |

### What *is* firmware dependent

| Firmware state | Effect |
|---|---|
| SDK older than the camera APK expects | the bug (this repo fixes the fatal one) |
| SDK newer than the camera APK expects | possible reverse mismatch — check with `analyze_sdk_skew.py` |
| `oplus_camera_feature_config` missing | feature flags fall back to defaults → modes silently unavailable |
| `com.oplus.aiunit` older than expected | new AI subsystem inert |
| HAL function list differs | the capture path can branch differently again |
| Sensor supports 16/50 MP | new build may expose higher resolutions (3468×4624 = 16 MP observed) where stock stayed at 12.5 MP |

---

## 4. Feature status on this device **with** the patch

| Feature | Status | Depends on |
|---|---|---|
| PHOTO / stills | ✅ works | — |
| PORTRAIT | ✅ works | — |
| Selfie (front camera) | ✅ works | — |
| NIGHT | ✅ works | — |
| Video recording | ✅ works | — |
| Multi-frame companion (`_01`) | ✅ works | — |
| 3A / auto-exposure / HDR / tone mapping | ✅ unchanged | — |
| JPEG quality (DQT 311/452) | ✅ unchanged | — |
| GR mode (clarity, particle, vignette) | ⚠️ inert | newer SDK + `oplus_camera_feature_config` |
| Vibe mode (global EV, tele zoom) | ⚠️ inert | newer SDK + config |
| Group photo (multi-device) | ⚠️ inert | newer SDK + config |
| Master watermark | ⚠️ inert | `MasterWatermarkJsonReader` class |
| Sports / `SportVideo` | ⚠️ inert | `CameraParameter$SportVideo*` classes |
| Fluency sampling | ⚠️ degraded | `CameraAdapterUtils.setFluencySampling` |
| Encrypted (private) logging | ⚠️ degraded | `CameraAdapterUtils.setEncryptEnable` |
| Gallery AV1 decode | ❌ removed in 6.070.215 | `libgav1JNI.so` dropped |
| In-app FFmpeg editing | ❌ removed in 6.070.215 | `libffmpeg.so` dropped |
| RTMP streaming | ❌ removed in 6.070.215 | `librtmp-jni.so` dropped |

---

## 5. Measured A/B — image quality

Same phone, same stand, same scene, stock and new build one minute apart.

| Metric | Stock 6.020.980 | New 6.070.215 | Same? |
|---|---|---|---|
| Resolution | 3072×4096 | 3072×4096 | ✅ |
| Exposure time | 0.019984 s | 0.019984 s | ✅ |
| Aperture | f/1.8 | f/1.8 | ✅ |
| Focal length | 5.59 mm (24 mm eq.) | 5.59 mm | ✅ |
| Flash | 16 | 16 | ✅ |
| JPEG DQT sums | 311 / 452 | 311 / 452 | ✅ |
| JPEG segment layout | EXIF, ICC, XMP, 2×DQT, 4×DHT | identical | ✅ |
| Ultra-HDR gain map | none | none | ✅ |

**⇒ identical imaging pipeline; the new build only changes the app layer.**

---

## 6. Other devices

The same patch should apply to any device where:

* the camera APK is **6.070.215 or newer**, **and**
* the installed `com.oplus.camera.unit.sdk.jar` still casts
  `KEY_PICTURE_EXIF_FLAG` to `int[]`, **and**
* the device is rooted with KernelSU (or another module system that can
  bind-mount).

Quick check on any device:

```bash
adb shell "grep -c 'check-cast v1, \[I' /dev/null" 2>/dev/null   # (placeholder)
# real check:
adb pull /product/framework/com.oplus.camera.unit.sdk.jar
apktool d com.oplus.camera.unit.sdk.jar -o sdk
grep -n "KEY_PICTURE_EXIF_FLAG" -A6 sdk/smali/com/oplus/ocs/camera/producer/mode/BaseMode.smali
```

If you see `check-cast v1, [I` right after the `KEY_PICTURE_EXIF_FLAG` read,
the device needs this patch.

---

## 7. Safety notes for this platform

| Hazard | What happens | Do this |
|---|---|---|
| `setenforce 0` (permissive SELinux) | MediaTek **MKP** integrity module panics the kernel and kills `system_server` → black screen, several reboots | **Never** do this. Use `resetprop` / a KernelSU module instead |
| Frida / frida-server | writes an SELinux policy to the kernel → same MKP panic | Remove frida-server if you used it |
| Bind-mounting a file over `/product/...` without fixing the SELinux label | the camera app cannot read the jar → `NoClassDefFoundError`, black preview | `chcon u:object_r:system_file:s0 <source>` before mounting |
| Leaving the module enabled across a ColorOS OTA | the newer SDK gets shadowed by this older patched build | `rm -rf /data/adb/modules/ocam_sdkfix` then reboot |
