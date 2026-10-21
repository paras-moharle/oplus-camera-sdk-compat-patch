# Oplus CameraUnit SDK compat patch

> **The Oplus camera takes no photos on firmware whose ODM is missing the AI libraries.**
> Three-patch fix, applied as a KernelSU module.

**Paras Moharle** · Tested on **OnePlus Nord 3** (CPH2491 / OP556FL1) · ColorOS 16 (16.0.5.1301) · Android 16

---

## The bug in 30 seconds

| | |
|---|---|
| **Symptom** | Shutter does nothing. No photo, no error, no log. Video works. **It affects the stock camera app too.** |
| **Cause 1 — the AI/APS gate** | The CameraUnit SDK always enters the AI/APS capture path (`BaseMode.isNeedAPSProcess()` is hard-coded `true`). That path needs `libai_perception_scene_detect.so`, `libarcsoft_hdr_denoise_api_v4.so`, `libImplicitWatermark.so`, `libUpScale.so` and the `com.oplus.aps.params.*` config, **none of which exist in this firmware's `/odm/lib64`**. The APS therefore never finishes initialising, and `ProducerImpl.takePicture()` cancels **every** capture with `CF_APS_FINISH_ADD_FRAME`. |
| **Cause 2 — the exif cast** (6.070.215+ only) | The new APK passes capture param `com.oplus.picture.exif.flag` as **`long[]`**; the device's CameraUnit SDK reads it back as **`(int[])`** → `ClassCastException` inside `takePicture()`. |
| **Cause 3 — the mount namespace** | The patched jar is only used if it is bind-mounted into the **zygote's** mount namespace *before* the camera app is forked from it. ART extracts `classes.dex` from the jar when the app process starts, so a mount that lands later is silently ignored — the symptom is "it works for a while, then it doesn't". |
| **Why silent** | 6.070.215 logs into the "private log" (`/data/vendor/cam_alog_*.txt`), which this firmware's SELinux policy does not allow the camera to write. The writer then retries ~3000×/s, pegs a CPU core and eventually gets the camera process killed. |

The camera's own private log is the proof:

```
E CameraUnit, ProducerImpl: takePicture, not allow take picture,
    mbApsFinishAddFrame: true, isApsCaptureAlgoInitializing: false, checkResult: 0, isCShot: false
E OCAM_ApsService: onCaptureFailed
E OCAM_CaptureProcessor: onApsCaptureFailed, capture: 1
```

Full write-up: **[docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md)**.

> **The stock camera app is affected too.** Downgrading the APK does not help:
> the gate lives in `/product/framework/com.oplus.camera.unit.sdk.jar`, which is
> firmware, not app. Measured on this device with the **unmodified stock
> 6.020.980** app: identical `CF_APS_FINISH_ADD_FRAME` cancellation.

---

## Optional: the 3–6 second shutter

**Symptom:** photos *do* arrive, but **3–6 seconds** after you press the
shutter; the preview stutters; video recording is refused when the phone is
warm. It affects the **stock camera too**, and it is present on a **stock
ROM** — it has nothing to do with root.

**Cause:** both camera builds hard-code `common_capture_temperature_threshold
= "41"` and compare it against the skin temperature reported by Oplus' *horae*
service (`dumpsys horae` → `Temp: 41.53`). A phone that idles at 40–44 °C is
*permanently* over that threshold, so the camera's capture-defer logic never
lets go. The threshold cannot be changed by configuration (the OEM code has a
key/lookup type mismatch that always falls back to the hard-coded value).

**Fix:** patch `oplus-framework.jar` so that **only the camera process** sees a
capped temperature. Every other app keeps the real one.

```bash
./install.sh --with-thermal-fix     # SDK patch + thermal bypass
./install_thermalfix.sh             # thermal bypass only
```

Details: **[docs/THERMAL-BYPASS.md](docs/THERMAL-BYPASS.md)**.


---

## Install (easiest: KernelSU module)

1. Download the latest **`ocam_sdkfix-v1.3.zip`** from the [Releases](https://github.com/paras-moharle/oplus-camera-sdk-compat-patch/releases) page.
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
# the patched jar must be visible in the ZYGOTE's mount namespace - that is
# the namespace every app is forked from
adb shell su -c 'nsenter -t $(pidof zygote64) -m -- md5sum /product/framework/com.oplus.camera.unit.sdk.jar'
adb shell su -c 'md5sum /data/adb/modules/ocam_sdkfix/SDK-PATCHED.jar'

adb logcat | grep -c "not allow take picture"   # must be 0
adb shell ls -lt /sdcard/DCIM/Camera/ | head -3
```

If the two hashes match and a photo appears, the fix is live.

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

Three methods in `/product/framework/com.oplus.camera.unit.sdk.jar`:

**1. `BaseMode.updateCaptureRequestTag()` — accept `long[]` as well as `int[]`**

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

**2. `BaseMode.isNeedAPSProcess()` — take the plain capture path**

```smali
 .method public isNeedAPSProcess()Z
     .locals 0
-    const/4 p0, 0x1                         ; always enter the AI/APS path
+    const/4 p0, 0x0                         ; plain path - the APS cannot run here
     return p0
 .end method
```

All four call sites are consistent with `false`: `KEY_NEED_APS_PROCESS` is not
set, `needApsProcessor()` returns false, `takePicture()` skips the APS
initialisation block and no preview multi-frame count is attached to the
request.

**3. `ProducerImpl.takePicture()` — the capture gate**

```smali
    :cond_3
-    iget-boolean v3, v0, …ProducerImpl;->mbApsFinishAddFrame:Z
+    const/4 v3, 0x1                         ; never cancel because APS did not finish
     if-nez v3, :cond_4
```

> **Do not implement this as an extra `goto`.** The smali assembler silently
> drops a branch that makes the following code unreachable, and the patch then
> does nothing at all. Replacing the field read with a constant survives
> assembly — and `install.sh` verifies the **built artifact**, not the source.

---

## The mount-namespace trap (why it "worked for a while, then didn't")

This is the part that makes this bug look intermittent, and it is worth
understanding before you change anything in the module.

```
init                    zygote                  com.oplus.camera
 |  mount --bind          |                         |
 |---------------------->|  (inherited)             |
 |                       |--- fork ---------------->|
 |                       |                         | ART extracts classes.dex
 |                       |                         | from the jar  <-- HERE
```

* `init` creates `/product/framework` as an **OverlayFS** whose lowerdir is
  `/mnt/vendor/my_product/product_overlay/framework/`.
* The **zygote unshares its own mount namespace** and makes the root mount a
  *slave*. Every mount that `init` performs **after** the zygote has started is
  therefore invisible to the zygote — and to every app forked from it.
* **ART extracts `classes.dex` from the jar when the app process starts.** A
  mount that appears later is never seen: the app keeps the stock classes and
  keeps cancelling captures, with no error anywhere.

That is why a watcher that mounts the patched jar into the *camera app's* own
namespace is useless — by the time the app exists, its dex is already
extracted. The mount has to be in the **zygote's** namespace, before the app
is forked.

Both are done by the module:

| When | Where | Why |
|---|---|---|
| `post-fs-data.sh` (≈ t=10 s) | init namespace **and** zygote namespace | wins the race against the zygote (≈ t=12–13 s) in the normal case |
| `service.sh` (watcher) | zygote namespace | closes the race when the zygote started first (this phone runs an MKP kernel-panic storm, load average 20+, and the zygote sometimes starts before `post-fs-data`) |
| `service.sh` (watcher) | camera app namespace | cosmetic: keeps the file consistent for code that opens the jar later |

**How to tell whether the patched classes are actually loaded** — compare the
dex signature that ART has in memory with the patched jar:

```bash
adb shell su -c 'grep camera.unit.sdk /proc/$(pidof com.oplus.camera)/maps'
adb shell su -c 'dd if=/proc/$(pidof com.oplus.camera)/mem bs=1 skip=<addr> count=48 | od -A n -t x1'
#   bytes 12..32 of the dex header are the SHA-1 signature:
#   patched  = 31 47 cd 68 66 09 ea c5 54 a0 47 76 4e 1c ac 76 29 4b ca ae 3b f8 77 81
#   original = 36 cc f9 11 85 50 21 90 d3 07 51 95 eb e9 10 6f 5d 7b ed 2d 54 2b
```

If the memory shows the *original* signature, the mount did not reach the
zygote namespace and the camera is still running stock code.

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
| **Flashed on a *different* device?** | The module **verifies** that the SDK on disk is byte-identical to the SDK its jar was built from. On a different firmware it refuses to mount — your camera stays broken rather than getting an incompatible SDK. Use `./install.sh` instead: it rebuilds the patch from *that* device's own SDK. |
| **After a ColorOS OTA** | **Disable the module.** An OTA ships a newer SDK. v1.2+ detects this automatically (the SDK hash no longer matches) and steps aside on its own. |

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

### The module's own safety rails

The boot scripts are deliberately paranoid — they only ever do a `mount --bind`,
and only when everything checks out:

| Guard | What it prevents |
|---|---|
| the patched jar must be complete (recorded size, or zip magic) | mounting a truncated / half-written file over the real SDK |
| the SDK on disk must be byte-identical (sha256) to the copy the jar was built from | flashing the release zip onto a device with different firmware, or an OTA silently replacing a newer SDK with an older one |
| already-mounted check (via `/proc/self/mountinfo`) | stacking mounts |
| every path exits 0 | the module can never fail a boot |

`tools/test_boot_guards.sh` runs these guards against a simulated filesystem:

```bash
bash tools/test_boot_guards.sh ksu-module/post-fs-data.sh
bash tools/test_boot_guards.sh ksu-module/service.sh
```


---

## Repo layout

```
README.md                    this file
LICENSE                      MIT
install.sh                   patch + install + reboot      (device side)
install_thermalfix.sh        optional: camera thermal bypass (device side)
uninstall.sh                 rollback  (--thermal also removes the bypass)
ksu-module/
  module.prop                KernelSU module metadata
  post-fs-data.sh            boot-time bind mount (init + zygote namespace)
  service.sh                 late-start fallback + camera-spin watchdog
  sepolicy.rule              lets the camera write its private log to /data/vendor
ksu-module-thermal/
  module.prop                KernelSU module metadata (optional module)
  post-fs-data.sh            boot-time bind mount of the framework jar
  service.sh                 late-start fallback
tools/
  patch_sdk.py               applies the three fixes to a decoded smali tree
  dexfp.py                   dex reader: inventory / fingerprint / compare
  analyze_sdk_skew.py        finds API skew between an APK and the device SDK
  build_release.sh           packages the flashable module zip
  build_thermalfix_zip.sh    packages the optional thermal module zip
  build_framework_patch.sh   decode + patch + rebuild + verify the framework jar
  patch_thermal_bypass.py    patches the camera-only thermal bypass
  test_boot_guards.sh        simulates the boot-script safety guards
docs/
  ROOT-CAUSE.md              the full investigation
  THERMAL-BYPASS.md          the optional 3-6 s shutter fix
  COMPATIBILITY.md           device / firmware matrix
  TROUBLESHOOTING.md         error signatures and what each one means
```

## License

MIT — see [LICENSE](LICENSE).
The patched jar is built from the target device's own firmware; no OEM
binary is committed to this repository.
