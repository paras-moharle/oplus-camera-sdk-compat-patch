# Oplus CameraUnit SDK compat patch

**Camera 6.070.215 takes no photos on firmware that still ships the 6.020.980 CameraUnit SDK.**
This repo contains the analysis, the one-line fix, and a reproducible installer.

> Author: **Paras Moharle** · Tested on: **OnePlus Nord 3 (CPH2491 / OP556FL1)**, ColorOS 16 (16.0.5.1301, BP2A.250605.015), Android 16

---

## TL;DR

| | |
|---|---|
| **Symptom** | Shutter does nothing. No photo, no error, no log. Video recording works fine. |
| **Root cause** | The new camera APK passes the capture parameter `com.oplus.picture.exif.flag` as **`long[]`**. The device's CameraUnit SDK reads it back with **`(int[])`** → `ClassCastException` inside `ProducerImpl.takePicture()` → the still-capture request is never built → the capture is cancelled. |
| **Why it is silent** | Camera 6.070.215 routes all of its logs into the "private log" (`/data/vendor/cam_alog/`), which the app is not allowed to write on this firmware. Every diagnostic is discarded. |
| **Fix** | Patch **one method** in the device's `com.oplus.camera.unit.sdk.jar` so that read accepts **both** `int[]` and `long[]`. The original file on disk is never modified — the patch is a bind mount. |
| **Result** | Photo, Portrait, Selfie, Night, Video all work. Image quality is byte-for-byte the same pipeline as the stock app. |

---

## 1. The problem, exactly

### 1.1 Symptom

With `com.oplus.camera` **6.070.215** installed on a Nord 3 running ColorOS 16 (16.0.5.1301):

* Tapping the shutter in **PHOTO / PORTRAIT / NIGHT / selfie** → *nothing happens*.
* The shutter button does not even animate.
* **No log line anywhere** — not in `logcat`, not in a crash log.
* **Video recording works.**
* The camera itself opens fine: preview streams, the session is configured correctly.

### 1.2 Where the capture actually dies

The MediaTek camera HAL never sees a still-capture request. Its own counter proves it:

```
# stock 6.020.980, one shutter press
isCapture(1) preCapTrig(1)   x6     <- the HAL got 6 capture requests

# new 6.070.215, one shutter press
isCapture(0) preCapTrig(0)   x86    <- the HAL never got a single one
```

Meanwhile `dumpsys media.camera` shows the new app configures the *correct* capture
surfaces — it is not a session-setup problem:

```
Consumer name: ImageReader-4096x3072f23m52-...     <- 12.5 MP JPEG still surface
Consumer name: ImageReader-4096x3072f20m52-...
Consumer name: ImageReader-2560x1920f32315659m52-...
Consumer name: ImageReader-1280x720f32315659m52-...
```

### 1.3 The exception (found by unlocking the app's private log)

The new app writes its logs through `CameraAdapterUtils.printPrivateLog()` →
native `libalog.so` → `/data/vendor/cam_alog/cam_alog_*.txt`. On this firmware
the app is not permitted to write there, so everything is thrown away:

```
E/APS_ALOG: FileALogWriter: file open failed /data/vendor/cam_alog_....txt
E/APS_ALOG: Unable to open file. Please disable SELinux and restart camerahalserver. !!!
```

Making the ALog fall back to `android.util.Log` (by making its native library
fail to load) exposes the real stack trace:

```
java.lang.ClassCastException: long[] cannot be cast to int[]
    at com.oplus.ocs.camera.producer.mode.BaseMode.updateCaptureRequestTag(BaseMode.java:1957)
    at com.oplus.ocs.camera.producer.mode.BaseMode.updateStageParameterBuilder(BaseMode.java:954)
    at com.oplus.ocs.camera.producer.mode.PhotoMode.updateStageParameterBuilder(PhotoMode.java:455)
    at com.oplus.ocs.camera.producer.ProducerImpl.buildStageParameter(ProducerImpl.java:395)
    at com.oplus.ocs.camera.producer.ProducerImpl.takePicture(ProducerImpl.java:849)
    at com.oplus.ocs.camera.CameraDeviceAdapterV2.takePicture(CameraDeviceAdapterV2.java:10)
    at com.oplus.ocs.camera.CameraDevice.takePicture(CameraDevice.java:7)
    at n8.u.a(CameraUnitDeviceProxy.java:34)
    at com.oplus.camera.module.processor.captureprocessor.CaptureProcessor.k(CaptureProcessor.java:207)
    at com.oplus.camera.module.BaseMode.If(BaseMode.java:111)
    at rj.u2.Hf(CommonCapMode.java:22)
    at com.oplus.camera.module.BaseMode.A7(BaseMode.java:107)
```

followed by

```
W/OCAM_CaptureProcessor: onDeviceCaptureCanceled, capture: 1
W/OCAM_CaptureProcessor: notifyCaptureFailed
W/OCAM_CaptureProcessor: completeCapture, capture: 1, success: false
```

### 1.4 The actual mismatch

**Camera APK 6.070.215** ships its own `com.oplus.ocs.camera.CameraParameter`
and declares that key with a **wider** Java type:

```java
// 6.020.980  (stock)
new PreviewKey("com.oplus.picture.exif.flag", int[].class);

// 6.070.215  (new)  -- const-class [J
new PreviewKey("com.oplus.picture.exif.flag", long[].class);
```

**Device CameraUnit SDK** (`/product/framework/com.oplus.camera.unit.sdk.jar`,
6.020.980-era) reads it back with a hard `int[]` cast:

```java
// BaseMode.updateCaptureRequestTag(), line 1957
int[] exifFlag = (int[]) builder.get(UTakePictureKeys.KEY_PICTURE_EXIF_FLAG);
if (exifFlag != null && exifFlag.length > 0) {
    cameraRequestTag.mExif = exifFlag[0];
}
```

⇒ `long[]` cannot be cast to `int[]` ⇒ the capture request is never built ⇒
no photo. **The HAL, the sensor, the ISP and the 3A engine are all innocent.**

---

## 2. Why the two builds got out of sync

Camera 6.070.215 is **not a standalone app** — it is one component of a newer
ColorOS/OnePlus firmware, and it is hard-coupled to the firmware components
that shipped alongside it.

API-diffing the two APKs against the SDK that is actually installed on the
device (`tools/analyze_sdk_skew.py`) shows 6.070.215 needs things this
firmware does not have:

| Missing in the device's SDK | Needed by 6.070.215 | Effect |
|---|---|---|
| `CameraUnitInterface.addSnapShotBuffer(Map)` | capture path | `NoSuchMethodError`, caught |
| `CameraUnitInterface.collectFluencyData()` | performance | `NoSuchMethodError`, caught |
| `CameraAdapterUtils.setEncryptEnable(boolean)` | log encryption | `NoSuchMethodError`, caught |
| `CameraAdapterUtils.setFluencySampling(boolean)` | performance | `NoSuchMethodError`, caught |
| `FilterProcessUnitSDK.getEffectFloatValue(String)` | filters | `NoSuchMethodError`, caught |
| `FilterProcessUnitSDK.getMSSdkVersion(Context)` | filters | `NoSuchMethodError`, caught |
| `FilterProcessUnitSDK.isTiledRenderSupported(Context)` | filters | signature change (old: no-arg) |
| `FilterGroupManager.init(Context, boolean, boolean)` | filters | `NoSuchMethodError`, caught |
| `CameraParameter$SportVideoType`, `$SportVideoEnableType` | sports mode | class missing |
| `MasterWatermarkJsonReader` (+`$JsonRestoreData`, `a`) | master watermark | class missing |
| `/odm/etc/camera/config/oplus_camera_feature_config` | feature flags | **file missing on device** |

Every one of these is swallowed as `NoSuchMethodError` — which is precisely
why the app degrades silently instead of crashing. The `picture_exif_flag`
cast was simply the one place where a swallowed error was fatal.

---

## 3. The fix

One method, one cast, made type-tolerant:

```smali
    move-result-object v1

    instance-of v6, v1, [J                       ; is it the new long[] form?

    if-eqz v6, :opplus_exif_flag_int_array

    check-cast v1, [J
    const/4 v6, 0x0
    aget-wide v2, v1, v6                         ; long[] -> element 0
    long-to-int v2, v2
    iput v2, p2, Lcom/oplus/ocs/camera/common/util/CameraRequestTag;->mExif:I
    goto :cond_0

    :opplus_exif_flag_int_array
    check-cast v1, [I                             ; original path, untouched
    if-eqz v1, :cond_0
    array-length v2, v1
    if-lez v2, :cond_0
    aget v1, v1, v0
    iput v1, p2, Lcom/oplus/ocs/camera/common/util/CameraRequestTag;->mExif:I
```

* `int[]` path (stock camera 6.020.980) → **bit-identical behaviour**.
* `long[]` path (camera 6.070.215) → the flag is read and truncated to `int`,
  exactly what the old SDK intended.

The patched jar is deployed as a **KernelSU module** that bind-mounts it over
`/product/framework/com.oplus.camera.unit.sdk.jar` at every boot.
**The original file on disk is never written to**, so removing the module
restores the stock behaviour instantly.

---

## 4. Install

```bash
git clone https://github.com/paras-moharle/oplus-camera-sdk-compat-patch.git
cd oplus-camera-sdk-compat-patch
./install.sh                # patches + installs the module + reboots
```

Requirements: `adb` with a **rooted** device, `apktool`, `python3`.

Options:

| Flag | Meaning |
|---|---|
| `--no-reboot` | install only, reboot when you like |
| `--force` | allow overwriting an existing install of the module |

Roll back at any time:

```bash
./uninstall.sh              # removes the module, restores the stock SDK
```

### Verify it worked

```bash
adb shell mount | grep camera.unit.sdk     # patched jar is bound over the original
adb shell dumpsys media.camera | grep -A2 "Active Camera Clients"
# open the camera, press the shutter, then:
adb shell ls -lt /sdcard/DCIM/Camera/ | head -3
adb logcat | grep -c ClassCastException   # must be 0
```

---

## 5. Is the new camera actually *better*? — measured A/B

Same phone, same stand, same scene, both builds, one minute apart:

| Metric | Stock 6.020.980 | New 6.070.215 | Verdict |
|---|---|---|---|
| Resolution (PHOTO 1x) | 3072×4096 (12.5 MP) | 3072×4096 (12.5 MP) | same |
| Exposure time | 0.019984 s | 0.019984 s | **identical** |
| Aperture | f/1.8 | f/1.8 | **identical** |
| Focal length | 5.59 mm (24 mm equiv.) | 5.59 mm | **identical** |
| Flash flag | 16 | 16 | **identical** |
| JPEG quantisation tables | DQT 311 / 452 | DQT 311 / 452 | **identical** |
| JPEG segment layout (EXIF/ICC/XMP/DQT/DHT) | — | same | **identical** |
| HDR gain map (Ultra HDR) | none | none | same |

**⇒ Per-frame image quality is effectively identical.** Same sensor, same HAL
tuning, same 3A/auto-exposure, same tone mapping, same JPEG encoder at the
same quality setting.

The stock camera is **not** a better photographer. What differs is the app
around the engine.

### What 6.070.215 adds (and 6.020.980 lacks)

| Area | New in 6.070.215 |
|---|---|
| Still retouch | **GR mode** — `com.oplus.gr.*` (clarity, particle amount/size, vignette) |
| New capture style | **Vibe mode** — `com.oplus.vibe.*` (global EV, tele-zoom point) |
| Group capture | **Group photo** — `com.oplus.group.photo.*`, full-binning QBC |
| Watermark | **Master watermark** system (`MasterWatermarkJsonReader`, `masterwatermark` pkg) |
| GPU pipeline | new `assets/postprocess/shaders/*.fs/.vs` (postprocess0-5, gaussianBlur, maskblit, blend, batchCut) |
| AI framing | `libmorpho_anchor_tracking` + `libmorphoAnchorTracking_jni` (anchor tracking) |
| AI guidance | `ai_capture_guide_composition.coz`, `ai_capture_guide_scan.coz`, `M_SenseME_Action_5.2.12.model` |
| AI architecture | `com.oplus.aisubsystem` + AIKit replaces `com.oplus.aiunit.core` |
| Capture params | `picture_exif_flag` widened to `long[]` (more EXIF capability bits), master preset, high-pixel dark env, flash-open trigger, lens-bag enable, external-flash status |
| UI | measurably snappier preview and a refreshed interface |

### What 6.070.215 drops

| Dropped | Consequence |
|---|---|
| `libffmpeg.so` | no in-app FFmpeg-based editing path |
| `libgav1JNI.so` | no AV1 decode in the camera/gallery path |
| `librtmp-jni.so` | no RTMP streaming |

---

## 6. What is hardware/firmware dependent

### The patch itself is **not** hardware dependent

| Aspect | Depends on hardware? | Why |
|---|---|---|
| The `long[]` vs `int[]` type mismatch | **No** — pure Java type contract | The camera APK and the SDK are both firmware components; the mismatch is a *firmware version* mismatch, not a silicon one |
| `ProducerImpl.takePicture()` path | **No** | shared by every camera mode (photo, portrait, selfie, night) and every sensor |
| Exif-flag truncation `long` → `int` | **No** | it is a 32-bit bitmask in both contracts |
| Preview / video | **No** | video never touches this parameter, which is why video always worked |
| Which symptoms you see | **No** | every still-capture mode fails identically |

### What *is* firmware dependent

| Firmware / device state | Consequence |
|---|---|
| Device ships a **6.020.980-era** CameraUnit SDK (this Nord 3) | photos dead until patched — **this repo's use case** |
| Device ships a **6.070.215-era** SDK (already accepts `long[]`) | patch is **unnecessary**; the app works out of the box |
| Device ships a **newer** SDK than the camera APK | app may break in the opposite direction (missing the *other* way round) |
| Missing `/odm/etc/camera/config/oplus_camera_feature_config` | feature flags fall back to defaults → some modes silently unavailable |
| `com.oplus.aiunit` older than the camera APK expects | new AI subsystem (GR / Vibe / group photo) stays inert |
| MTK camera HAL that never advertised the required function flags | the capture path can branch differently again |
| Sensor with 16 MP / 50 MP modes | the new build may expose higher resolutions (a 3468×4624 = 16 MP frame was observed) where the stock app stayed at 12.5 MP |

### ⚠️ After a ColorOS OTA

The module bind-mounts a jar built for **your current** SDK over
`/product/framework/com.oplus.camera.unit.sdk.jar`. If an OTA ships a **newer**
SDK, the mount would hide it with an older build. **Disable the module right
after an OTA**, then re-test:

```bash
adb shell su -c "rm -rf /data/adb/modules/ocam_sdkfix" && adb reboot
```

---

## 7. What will and will not work (this device, with the patch)

| Feature | Status | Notes |
|---|---|---|
| PHOTO (stills) | ✅ works | the patch's whole purpose |
| PORTRAIT | ✅ works | same capture path |
| Selfie / front camera | ✅ works | same capture path |
| NIGHT | ✅ works | same capture path |
| Video recording | ✅ worked before *and* after | never touched by this bug |
| Multi-frame / companion `_01` frame | ✅ | both builds save it |
| Image quality (3A, HDR, tone, JPEG) | ✅ unchanged | measured identical, see §5 |
| GR mode (clarity / particle / vignette) | ⚠️ inert | needs a newer SDK + `oplus_camera_feature_config` |
| Vibe mode (global EV, tele zoom) | ⚠️ inert | same reason |
| Group photo | ⚠️ inert | same reason |
| Master watermark | ⚠️ inert | class `MasterWatermarkJsonReader` missing |
| Sports / `SportVideo` | ⚠️ inert | classes missing |
| Fluency sampling / encrypted log | ⚠️ degraded | methods missing (caught) |
| Gallery AV1 decode / RTMP stream | ❌ removed | libs dropped in 6.070.215 |

---

## 8. Repo layout

```
.
├── README.md                     this document
├── LICENSE                       MIT
├── install.sh                    patch + install + reboot
├── uninstall.sh                  rollback
├── ksu-module/
│   ├── module.prop               KernelSU module metadata
│   └── post-fs-data.sh           boot-time bind mount
├── tools/
│   ├── patch_sdk.py              applies the fix to a decoded smali tree
│   ├── dexfp.py                  dex reader: inventory / fingerprint / compare
│   └── analyze_sdk_skew.py       finds API skew between an APK and the device SDK
└── docs/
    ├── ROOT-CAUSE.md             the full investigation write-up
    └── COMPATIBILITY.md          device / firmware compatibility matrix
```

No OEM binaries are committed: the patched jar is always built from the
device's own `/product/framework/com.oplus.camera.unit.sdk.jar` at install
time, so the repo stays free of proprietary redistribution.

---

## 9. Credits & notes

* Reverse engineering was done locally with `apktool`, `baksmali` and a
  small purpose-built DEX reader (`tools/dexfp.py`).
* No proprietary file is redistributed; the SDK jar is read from and patched
  on the target device only.
* The stock camera app remains fully supported by this patch — the `int[]`
  code path is byte-for-byte the original.

```
Author : Paras Moharle
Device : OnePlus Nord 3 (CPH2491 / OP556FL1)
Firmware : ColorOS 16 - 16.0.5.1301 (BP2A.250605.015) / Android 16
```

## License

MIT — see [LICENSE](LICENSE).
