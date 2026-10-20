# Oplus CameraUnit SDK compat patch

> **Camera 6.070.215 takes no photos on firmware that still ships the 6.020.980 CameraUnit SDK.**
> One-line fix, applied as a KernelSU module.

**Paras Moharle** · Tested on **OnePlus Nord 3** (CPH2491 / OP556FL1) · ColorOS 16 (16.0.5.1301) · Android 16

---

## The bug in 30 seconds

| | |
|---|---|
| **Symptom** | Shutter does nothing. No photo, no error, no log. Video works. |
| **Cause** | New APK passes capture param `com.oplus.picture.exif.flag` as **`long[]`**; the device's CameraUnit SDK reads it back as **`(int[])`** → `ClassCastException` inside `takePicture()` → the capture request is never built. |
| **Why silent** | 6.070.215 logs into the "private log" (`/data/vendor/cam_alog/`) which the app cannot write on this firmware — every diagnostic is discarded. |
| **Fix** | Make that one read accept **both** `int[]` and `long[]`. |

The MTK HAL's own counter is the proof:

```
stock 6.020.980 :  isCapture(1) preCapTrig(1)  x6     <- capture reached the HAL
new   6.070.215 :  isCapture(0) preCapTrig(0)  x86    <- never a capture request
```

and the exception (recovered by making the ALog fall back to `logcat`):

```
java.lang.ClassCastException: long[] cannot be cast to int[]
    at com.oplus.ocs.camera.producer.mode.BaseMode.updateCaptureRequestTag(BaseMode.java:1957)
    at com.oplus.ocs.camera.producer.ProducerImpl.takePicture(ProducerImpl.java:849)
    ...
W/OCAM_CaptureProcessor: completeCapture, capture: 1, success: false
```

Full write-up: **[docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md)**.

---

## Install (easiest: KernelSU module)

1. Download **`ocam_sdkfix-v1.0.zip`** from the [Releases](https://github.com/paras-moharle/oplus-camera-sdk-compat-patch/releases) page.
2. KernelSU Manager → **Modules** → **Install from storage** → pick the zip → reboot.
3. Open the camera and take a photo.

<details>
<summary>Or build &amp; install from source (recommended — no proprietary binary is downloaded)</summary>

```bash
git clone https://github.com/paras-moharle/oplus-camera-sdk-compat-patch.git
cd oplus-camera-sdk-compat-patch
./install.sh                # pulls your device's own SDK jar, patches it, installs the module, reboots
```

The jar is always built **from the target device's own**
`/product/framework/com.oplus.camera.unit.sdk.jar`, so no OEM binary is
distributed. `install.sh` refuses to clobber an existing install unless you
pass `--force`; `--no-reboot` skips the reboot.
</details>

### Verify

```bash
adb shell mount | grep camera.unit.sdk        # patched jar bound over the original
adb logcat | grep -c ClassCastException       # must be 0
adb shell ls -lt /sdcard/DCIM/Camera/ | head -3
```

### Rollback

```bash
./uninstall.sh          # removes the module; the stock SDK is restored untouched
```

> The original file on disk is **never modified** — the patch is a bind mount.
> `sha256sum /product/framework/com.oplus.camera.unit.sdk.jar` still shows the
> pristine OEM hash after installing.
>
> If your device has a KernelSU **metamodule with a custom installer** active,
> it blocks `ksud module install` ("Metamodule installation blocked"). Use
> `./install.sh`, which writes the module directory directly, or install the
> release zip once the metamodule is disabled.
>
> If the module is ever removed by a bootloop-saver, re-apply the patch
> without rebooting:
> ```bash
> adb shell su -c sh /data/local/tmp/ocam-apply.sh
> ```


---

## What changed, exactly

One method in `/product/framework/com.oplus.camera.unit.sdk.jar`:

```smali
    move-result-object v1
    instance-of v6, v1, [J                   ; new long[] form?
    if-eqz v6, :opplus_exif_flag_int_array
    check-cast v1, [J
    const/4 v6, 0x0
    aget-wide v2, v1, v6                     ; long[] -> element 0
    long-to-int v2, v2
    iput v2, p2, …CameraRequestTag;->mExif:I
    goto :cond_0
    :opplus_exif_flag_int_array
    check-cast v1, [I                         ; original path, untouched
    …
```

The `int[]` path is byte-for-byte the original ⇒ the **stock camera app is
unaffected**.

---

## Is the new camera better? — measured A/B

Same phone, same stand, same scene, both builds one minute apart:

| Metric | Stock 6.020.980 | New 6.070.215 | Same? |
|---|---|---|---|
| Resolution (PHOTO 1x) | 3072×4096 | 3072×4096 | ✅ |
| Exposure | 0.019984 s | 0.019984 s | ✅ |
| Aperture | f/1.8 | f/1.8 | ✅ |
| Focal length | 5.59 mm (24 mm eq.) | 5.59 mm | ✅ |
| Flash flag | 16 | 16 | ✅ |
| JPEG quant tables (DQT) | 311 / 452 | 311 / 452 | ✅ |
| JPEG segment layout | EXIF/ICC/XMP/2×DQT/4×DHT | identical | ✅ |
| Ultra-HDR gain map | none | none | ✅ |

**⇒ per-frame image quality is identical.** Same sensor, HAL tuning, 3A,
tone mapping and JPEG encoder. The stock app is *not* a better photographer —
it is the same camera with a different app around it.

**New in 6.070.215:** GR mode (clarity/particle/vignette) · Vibe mode · group
photo · master watermark · a new GPU post-processing pipeline
(`assets/postprocess/shaders/*`) · morpho AI anchor tracking · AI
composition/scan guides · a new `com.oplus.aisubsystem` AIKit architecture ·
wider capture parameters (the `long[]` exif flag, master preset, high-pixel
dark env, flash-open trigger, lens-bag enable).

**Dropped in 6.070.215:** `libffmpeg.so` (in-app editing), `libgav1JNI.so`
(AV1 decode), `librtmp-jni.so` (RTMP streaming).

---

## Will it work on my device?

| | |
|---|---|
| **Patch is hardware dependent?** | **No.** It is a Java type contract between two *firmware* components. No HAL, ISP, sensor or tuning data is touched. |
| **Needs a matching camera APK?** | Yes — camera **6.070.215 or newer** against a **6.020.980-era** SDK. Both sides of that equation are firmware, not silicon. |
| **Detection** | `grep -A6 KEY_PICTURE_EXIF_FLAG` in the decoded `producer/mode/BaseMode.smali` — if you see `check-cast v1, [I` right after the read, you need this. |
| **After a ColorOS OTA** | **Disable the module.** An OTA ships a newer SDK and the mount would shadow it with this older build. |

---

## What works on the Nord 3 with the patch

| Feature | Status | Why |
|---|---|---|
| PHOTO / PORTRAIT / selfie / NIGHT | ✅ works | the point of the patch |
| Video | ✅ | never touched by this bug |
| Multi-frame companion frame (`_01`) | ✅ | both builds do it |
| 3A, HDR, tone mapping, JPEG quality | ✅ unchanged | measured identical |
| GR mode · Vibe mode · group photo · master watermark · sports | ⚠️ inert | need a newer SDK + `oplus_camera_feature_config` + AIUnit |
| Gallery AV1 · in-app FFmpeg editing · RTMP | ❌ removed in 6.070.215 | libs dropped |

### The wider version skew

`tools/analyze_sdk_skew.py` finds 7 methods 6.070.215 needs and this
firmware lacks (all swallowed as `NoSuchMethodError`):

```
CameraUnitInterface.addSnapShotBuffer(Map)          CameraAdapterUtils.setEncryptEnable(boolean)
CameraUnitInterface.collectFluencyData()            CameraAdapterUtils.setFluencySampling(boolean)
FilterProcessUnitSDK.getEffectFloatValue(String)   FilterProcessUnitSDK.getMSSdkVersion(Context)
FilterProcessUnitSDK.isTiledRenderSupported(Context)
```

plus missing classes (`CameraParameter$SportVideo*`, `MasterWatermarkJsonReader`)
and a missing `/odm/etc/camera/config/oplus_camera_feature_config`.
That skew is why the app *degrades* instead of crashing — and why this one
uncaught cast became invisible.

Full matrix: **[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)**.

---

## ⚠️ Platform warnings (MediaTek / Nord 3)

| Never do this | Why |
|---|---|
| `setenforce 0` (permissive SELinux) | MediaTek's **MKP** integrity module hashes the SELinux state and panics the kernel → black screen, reboot loop. This is what caused the very first crash in this investigation. |
| Run frida / frida-server | it writes an SELinux policy to the kernel → same MKP panic |
| `chcon` / `setfattr` / `setenforce` from a **boot-time** script | same MKP panic. **This module therefore sets the SELinux label exactly once, at install time**, and its boot scripts do nothing but `mount --bind`. |
| Bind-mount over `/product/...` with the wrong label | the camera app cannot read the jar → `NoClassDefFoundError`, instant crash. The jar keeps the `system_file` label the original had. |

> Note: on this device MKP also panics continuously from unrelated modules
> (`zygisk_vector`, `rezygisk`, …). If `dmesg | grep policy_action_panic` is
> already counting up while the patch is disabled, that is **not** the patch.


---

## Repo layout

```
README.md                    this file
LICENSE                      MIT
install.sh                   patch + install + reboot      (device side)
uninstall.sh                 rollback                      (device side)
ksu-module/
  module.prop                KernelSU module metadata
  post-fs-data.sh            boot-time bind mount
tools/
  patch_sdk.py               applies the fix to a decoded smali tree
  dexfp.py                   dex reader: inventory / fingerprint / compare
  analyze_sdk_skew.py        finds API skew between an APK and the device SDK
docs/
  ROOT-CAUSE.md              the full investigation
  COMPATIBILITY.md           device / firmware matrix
```

## License

MIT — see [LICENSE](LICENSE).
The patched jar is built from the target device's own firmware; no OEM
binary is committed to this repository.
