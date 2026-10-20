# Root cause — the full write-up

**Author:** Paras Moharle · **Device:** OnePlus Nord 3 (CPH2491 / OP556FL1), ColorOS 16 16.0.5.1301, Android 16

---

## 0. TL;DR

```
camera APK 6.070.215   ──declares──▶  "com.oplus.picture.exif.flag" : long[]
                                                            │
                                                            ▼
device CameraUnit SDK   ──reads───▶  (int[]) value   →   ClassCastException
                                                            │
                                                            ▼
                                     ProducerImpl.takePicture() aborts
                                                            │
                                                            ▼
                                     no capture request reaches the HAL
                                                            │
                                                            ▼
                                     photo never written, silently
```

---

## 1. Setting

Two `com.oplus.camera` builds were compared:

| Build | Version | Location | Photo | Video |
|---|---|---|---|---|
| stock | **6.020.980** | `/product/app/OplusCamera/OplusCamera.apk` | ✅ | ✅ |
| new | **6.070.215** | user-supplied APK | ❌ | ✅ |

Both have the **same package name** (`com.oplus.camera`), the **same
versionCode** (60000) and a **byte-identical `AndroidManifest.xml`**. The
difference is entirely in code and resources.

Device: OnePlus **Nord 3** (CPH2491 / OP556FL1), Snapdragon 782G, MTK camera HAL,
ColorOS 16 (16.0.5.1301, build `BP2A.250605.015`), Android 16 (SDK 36).

---

## 2. Ruling things out first

| Hypothesis | Test | Result |
|---|---|---|
| Camera HAL / sensor / ISP problem | `dumpsys media.camera` with both builds | **Identical** session setup, identical JPEG surfaces (`ImageReader-4096x3072f23m52`, `ImageReader-4096x3072f20m52`, `ImageReader-2560x1920…`, `ImageReader-1280x720…`) |
| Shutter button dead / touch not delivered | `uiautomator dump` | Button present, `enabled=true clickable=true`; `OplusViewDragTouchViewHelper: dispatchTouchView action = 1` shows the touch **is** delivered |
| App not responding | Thread dump (`kill -3`) | All threads idle, none blocked |
| Permission problem | `pm list packages`, `dumpsys package` | Camera granted, `SYSTEM_CAMERA` held as a priv-app |
| Stale app state | `pm clear com.oplus.camera` | Still broken → **not** a state issue |
| AI Unit version | Rollback 16.2.4 → 16.1.32 | Still broken → **not** the AI Unit |
| HAL rejects the request | MTK HAL's own counter | The HAL **never receives** a request → the app never sends one |

**The decisive observation** was the HAL-side counter in
`mtkcam-SensorControl: [postProcDoDecision] … isCapture(1) preCapTrig(1)`:

| Build | after one shutter press |
|---|---|
| stock | `isCapture(1) preCapTrig(1)` × 6 |
| new | `isCapture(0) preCapTrig(0)` × 86 — **never** a capture request |

So the failure is **above the HAL**: the app never asks for a photo.

---

## 3. Why there was no log at all

This was the hardest part of the investigation, because the app is *silent by
design* on this firmware.

Camera 6.070.215 routes its diagnostics through the **private log**:

```
m8/c.h(tag, msg)  ─►  CameraUnitUtils.printPrivateLog(...)
                   └─► CameraAdapterUtils.printPrivateLog(...)
                       └─► ALog.printLog(tag, msg, level)   (system SDK jar)
                           └─► native libAPSClient-alog-jni.so / libalog.so
                               └─► /data/vendor/cam_alog/cam_alog_<date>_<pid>_NN.txt
```

On this device the app cannot write there, so every line is dropped:

```
E/APS_ALOG: CAM_ALOG_LIMIT,Fatal Err! mFd -1
E/APS_ALOG: Failed to open directory
E/APS_ALOG: FileALogWriter: file open failed /data/vendor/cam_alog_2026_...txt
E/APS_ALOG: Unable to open file. Please disable SELinux and restart camerahalserver. !!!
```

The stock build logs straight to `android.util.Log`, which is why it was
verbose and the new build was mute.

**The unlock:** `ALog.printLog()` falls back to `android.util.Log` when the
native library fails to load:

```java
public static int printLog(String tag, String msg, int level) {
    if (sJNILoadFailed) {                 // <-- library did not load
        switch (level) { … }
        return Log.e(tag, msg);            // <-- straight to logcat
    }
    return alogPrint(tag, msg, level);
}
```

Making `libAPSClient-alog-jni.so` unloadable (bind-mounting a non-ELF stub
over it) instantly produced 1500+ app log lines — including the stack trace
that ended the investigation.

> ⚠️ Do **not** leave that stub in place: the camera HAL uses the same ALog
> library and the black preview that results is a false alarm. Unmount it.

---

## 4. The stack trace

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
    at n8.j0.run(R8$$SyntheticClass:397)
    at q7.c.e(CameraHandlerThread.java:11)
    at com.oplus.camera.module.processor.captureprocessor.CaptureProcessor.k(CaptureProcessor.java:207)
    at com.oplus.camera.module.BaseMode.If(BaseMode.java:111)
    at rj.u2.Hf(CommonCapMode.java:22)
    at com.oplus.camera.module.BaseMode.A7(BaseMode.java:107)
    at rj.b0.run(R8$$SyntheticClass:283)
```

and the app-side consequences:

```
W/OCAM_CaptureProcessor: onDeviceCaptureCanceled, capture: 1
W/OCAM_CaptureProcessor: notifyCaptureFailed
W/OCAM_CaptureProcessor: completeCapture, capture: 1, success: false
W/OCAM_CommonCapMode:  resetWhenCaptureFail, mActivity: com.oplus.camera.Camera@…, mbPaused: false
```

---

## 5. Pinpointing the exact line

The system jar was decoded and the source line from the stack trace
(`BaseMode.java:1957`) was located through the `.line` debug markers:

```smali
.method protected updateCaptureRequestTag(PreviewParameter$Builder;CameraRequestTag;String;)V
    .locals 10
    …
    .line 1957
    sget-object v1, Lcom/oplus/ocs/camera/metadata/UTakePictureKeys;->KEY_PICTURE_EXIF_FLAG:Lcom/oplus/ocs/camera/metadata/PreviewKey;
    invoke-virtual {p1, v1}, …PreviewParameter$Builder;->get(…)Ljava/lang/Object;
    move-result-object v1
    check-cast v1, [I                     <<<<<< line 1957: the fatal cast
    if-eqz v1, :cond_0
    array-length v2, v1
    if-lez v2, :cond_0
    aget v1, v1, v0
    iput v1, p2, …CameraRequestTag;->mExif:I
```

The **key type** lives in the camera APK (both APKs ship
`com.oplus.ocs.camera.CameraParameter`):

```java
// 6.020.980  (stock)                          // 6.070.215  (new)
new PreviewKey("com.oplus.picture.exif.flag",  // new PreviewKey("com.oplus.picture.exif.flag",
                      int[].class)             //                      const-class [J)
```

The key **name** is the same, so the value written by the new app is found by
the old SDK — and then blows up on the cast.

---

## 6. The wider version skew

`tools/analyze_sdk_skew.py` compares every `invoke-*` target on a
`com.oplus.ocs.*` class in the APK against the method table of the SDK jars
actually installed on the device.

**6.070.215-only requirements missing from this device's SDK:**

| Symbol | Note |
|---|---|
| `CameraUnitInterface.addSnapShotBuffer(Map)` | capture path |
| `CameraUnitInterface.collectFluencyData()` | performance |
| `CameraAdapterUtils.setEncryptEnable(boolean)` | log encryption |
| `CameraAdapterUtils.setFluencySampling(boolean)` | performance |
| `FilterProcessUnitSDK.getEffectFloatValue(String)` | filters |
| `FilterProcessUnitSDK.getMSSdkVersion(Context)` | filters |
| `FilterProcessUnitSDK.isTiledRenderSupported(Context)` | old signature had no arg |
| `FilterGroupManager.init(Context, boolean, boolean)` | filters |
| `CameraParameter$SportVideoType`, `$SportVideoEnableType` | classes |
| `MasterWatermarkJsonReader`, `$JsonRestoreData`, `a` | classes |
| `/odm/etc/camera/config/oplus_camera_feature_config` | config file absent |

All of them are caught as `NoSuchMethodError`/`ClassNotFoundException` inside
the app, which is exactly why the app *degrades* instead of crashing — and why
the one uncaught cast became invisible.

---

## 7. The patch

`tools/patch_sdk.py` rewrites the single read to be type-tolerant:

```smali
    move-result-object v1
    instance-of v6, v1, [J
    if-eqz v6, :opplus_exif_flag_int_array
    check-cast v1, [J
    const/4 v6, 0x0
    aget-wide v2, v1, v6
    long-to-int v2, v2
    iput v2, p2, …CameraRequestTag;->mExif:I
    goto :cond_0
    :opplus_exif_flag_int_array
    check-cast v1, [I          ; original path, unchanged
    …
```

Two real bugs were hit while building it, both worth recording:

1. **Register clash.** The first attempt used `v10`/`v11` for the `long`
   value. In this method `.locals 10` + 3 parameters means `v10..v12` **are**
   the parameters — the patch silently overwrote `p1`/`p2`. ART rejected the
   class:

   ```
   VerifyError: Verifier rejected class …BaseMode: … updateCaptureRequestTag(…)
                failed to verify
   ```

   which surfaced as `Rejecting class …PhotoMode that attempts to sub-type
   erroneous class …BaseMode` and a **black preview**. Fixed by using `v6` and
   the `v2/v3` wide pair.

2. **Duplicate `move-result-object`.** The replacement block re-emitted the
   `move-result-object v1` that already preceded the cast, leaving a
   `move-result` with no result — again a `VerifyError`.

Both were caught by the inventory check in `tools/dexfp.py compare`, which
proves the rebuilt jar contains **exactly** the same classes and methods as
the original.

---

## 8. Deployment

`/product` is **EROFS** (read-only), so the patched jar cannot be written
there. It is deployed as a **bind mount** from a KernelSU module:

```
/data/adb/modules/ocam_sdkfix/
├── module.prop
├── post-fs-data.sh     # mount --bind $SRC /product/framework/com.oplus.camera.unit.sdk.jar
├── SDK-PATCHED.jar     # built on the device itself
└── SDK-ORIGINAL.jar    # untouched copy, for reference
```

**Critical detail:** a bind mount makes the *source* file's SELinux label
visible at the target path. The module `chcon`s the source to
`u:object_r:system_file:s0`; without that, the camera app (running as
`untrusted_app`) cannot read the jar and dies immediately with:

```
NoClassDefFoundError: Failed resolution of: Lcom/oplus/ocs/camera/appinterface/adapter/CameraAdapterUtils;
```

---

## 9. Verification

| Check | Before | After |
|---|---|---|
| `ClassCastException` in logcat on shutter press | 1 per press | **0** |
| MTK HAL `isCapture(1)` after a shutter press | 0 | **6** |
| `OCAM_CaptureProcessor: completeCapture … success: false` | yes | **no** |
| New files in `/sdcard/DCIM/Camera/` | none | **yes**, 3072×4096 JPEGs |
| PHOTO / PORTRAIT / NIGHT / selfie | all dead | **all working** |
| Video | working | working (untouched) |

---

## 10. Side effects / safety

| Item | State |
|---|---|
| `/product/framework/com.oplus.camera.unit.sdk.jar` on disk | **never written** — only shadowed by a bind mount |
| SELinux enforcement | `Enforcing` (never left permissive) |
| `/data/vendor` SELinux context | restored to `vendor_data_file` |
| `ro.version.confidential` | restored to `false` |
| `com.oplus.aiunit` | rolled back to the system 16.1.32 (16.2.4 was removed while testing) |
| Debug tooling (frida) | removed; the MTK MKP kernel module panics on a permissive SELinux state and kills `system_server` — **do not use `setenforce 0` on this device** |

---

## 11. What is *not* fixed by this patch

The patch unblocks the capture path only. The remaining version skew stays, so
these newer camera features remain **inert** on this firmware:

GR mode · Vibe mode · group photo · master watermark · sports video ·
fluency sampling · encrypted logging.

They need the matching `com.oplus.camera.unit.sdk.jar`,
`oplus_camera_feature_config` and `com.oplus.aiunit` from the same ColorOS
release as camera 6.070.215.

**And after a ColorOS OTA — disable the module**, or it will replace the new
SDK with this older patched build.
