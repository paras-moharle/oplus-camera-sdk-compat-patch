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
| **Cause 3 — the mount namespace** | The patched jar is only used if every path lookup of `/product/framework/com.oplus.camera.unit.sdk.jar` lands on it. Every app gets a fresh mount namespace in which bind mounts are stripped, and the OEM's OverlayFS pins its lowerdir — so the module delivers the jar through a **kernel VFS path redirect** (NoMount), which is namespace independent. A bind mount works "for a while" and then silently reverts to the stock jar. |
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

## The 3–6 second shutter (part of the same module)

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
capped temperature. Every other app keeps the real one. It is part of the same
module as the SDK patch, and it can be **switched on and off at run time with
the volume keys** (see *The thermal bypass has a runtime switch* above).

Details: **[docs/THERMAL-BYPASS.md](docs/THERMAL-BYPASS.md)**.


---

## Install (easiest: KernelSU module)

One module does both fixes. Download **`ocam_camfix-v3.0.zip`** from the
[Releases](https://github.com/paras-moharle/oplus-camera-sdk-compat-patch/releases) page:

1. KernelSU Manager → **Modules** → **Install from storage** → pick the zip → reboot.
2. Open the camera and take a photo.

<details>
<summary>Or build &amp; install from source (recommended — no proprietary binary is downloaded)</summary>

```bash
git clone https://github.com/paras-moharle/oplus-camera-sdk-compat-patch.git
cd oplus-camera-sdk-compat-patch
./install.sh                # pulls your device's own jars, patches them, installs the module, reboots
```

Both jars are always built **from the target device's own**
`/product/framework/com.oplus.camera.unit.sdk.jar` and
`/system/framework/oplus-framework.jar`, so no OEM binary is distributed.
`install.sh` refuses to clobber an existing install unless you pass
`--force`; `--no-reboot` skips the reboot.
</details>

### The thermal bypass has a runtime switch

The camera defers every capture while the phone is warmer than 41 °C. The
module hides that from the camera process only — and it can be **switched on
and off while the phone is running**:

| Gesture | Action |
|---|---|
| **hold volume-down for 2 s** | toggle the thermal bypass |
| **hold volume-up for 2 s** | show the state and the real skin temperature |

A short press still changes the volume as usual — the key events are only
*read* by the module, never consumed. You get a notification either way.

This works without a reboot because the patched
`OplusHoraeThermalHelper` reads the switch on **every call**:

```
persist.oplus.camera.thermal_bypass      1 = on (default), 0 = off
```

The property is `persist.*`, so your choice survives a reboot.

> Why not just re-mount the jar? Because `oplus-framework.jar` is a
> **bootclasspath** jar: the zygote opens it once at boot and keeps it
> mapped, so `umount` fails with *"Device or resource busy"* and the mount
> can only be created at boot time. A property check inside the class is the
> only way to switch it live.

### Verify

```bash
# the OEM path must resolve to the patched jar (size 4946456, not 4926415)
adb shell su -c 'stat -Lc %s /product/framework/com.oplus.camera.unit.sdk.jar'
# the OEM prebuilt dexopt artifact must be masked
adb shell su -c 'stat -Lc %s /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex'
# the app must map the extracted dex, not the stock file
adb shell su -c 'grep camera.unit.sdk /proc/$(pidof com.oplus.camera)/maps'

adb logcat | grep -c "not allow take picture"   # must be 0
adb shell getprop persist.oplus.camera.thermal_bypass
adb shell ls -lt /sdcard/DCIM/Camera/ | head -3
```

If the two hashes match and a photo appears, the fix is live.

### Rollback

```bash
./uninstall.sh          # removes the module; both stock jars are restored untouched
```

> The original file on disk is **never modified** — the patch is a kernel VFS
> redirect (and, for the thermal jar, a bind mount). `sha256sum` of the OEM
> files still shows the pristine hashes after installing.
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

## Why a bind mount cannot work (and what does)

This is the part that makes this bug look intermittent, and it is worth
understanding before you change anything in the module.

* **Every app process gets its own, freshly built mount namespace** — and every
  mount this module made is removed from it (KernelSU's *kmount* feature and
  the Zygisk *denamespace* step both do that, to hide modules from apps). The
  app then sees the OEM filesystem again.
* `/product/framework` is an **OverlayFS** whose lowerdir is a read-only image.
  OverlayFS **pins the lowerdir dentry when the overlay is created**, so a
  bind mount over the merged path — or over the lowerdir path — is never seen
  by an `open()` that goes through the overlay.
* **ART extracts `classes.dex` from the jar when the app process starts.** A
  mount that appears later is never seen either.

So there is no mount that the camera can see. What *does* survive is a
**kernel VFS path redirect**: this device runs the **NoMount** metamodule
(`nm`, v2.1.1), which rewrites path lookups in the kernel. That is namespace
independent, so every process — in every namespace, including a namespace
created after the rule — opens the patched jar.

| What | Mechanism | Why |
|---|---|---|
| `com.oplus.camera.unit.sdk.jar` | NoMount rule: `/product/framework/…jar` → `<module>/product/framework/…jar` | survives the per-app mount namespace |
| OEM `oat/arm64/com.oplus.camera.unit.sdk.{odex,vdex}` | NoMount rules to **zero-length** files | the OEM artifacts were compiled from the *stock* jar; ART must be forced to extract the dex from ours |
| `oplus-framework.jar` (thermal) | bind mount, created in `post-fs-data.sh` **before** the zygote starts | it is a **bootclasspath** jar: the zygote opens it once at boot and keeps it mapped, so the mount only has to exist at that moment |

The module **ships the redirect tree itself**:

```
/data/adb/modules/ocam_camfix/
├── SDK-PATCHED.jar                                  # source of truth
└── product/framework/
    ├── com.oplus.camera.unit.sdk.jar                # the patched jar
    └── oat/arm64/com.oplus.camera.unit.sdk.{odex,vdex}   # empty
```

NoMount's `metamount.sh` walks every module's `product/` tree at boot and
injects these rules automatically, before the zygote and before any app
starts. `post-fs-data.sh` adds them again (idempotent) and verifies the
result; `service.sh` re-verifies every 10 seconds and repairs a lost rule —
and notifies you if it ever cannot.

**How to tell whether the patched classes are actually loaded** — one command:

```bash
adb shell su -c 'stat -Lc %s /product/framework/com.oplus.camera.unit.sdk.jar'
# patched jar = 4946456      (the OEM stock jar is 4926415)
adb shell su -c 'stat -Lc %s /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex'
# 0                          (the OEM prebuilt artifact is masked)

adb shell su -c 'grep camera.unit.sdk /proc/$(pidof com.oplus.camera)/maps'
# must show  [anon:dalvik-classes.dex extracte... /product/framework/com.oplus.camera.unit.sdk.jar]
# if it shows  /product/framework/com.oplus.camera.unit.sdk.jar  as a FILE, the redirect is missing
```

You can also compare the dex signature ART has in memory with the patched jar:

```bash
adb shell su -c 'dd if=/proc/$(pidof com.oplus.camera)/mem bs=1 skip=<addr+12> count=32 | od -A n -t x1'
#   bytes 12..32 of the dex header are the SHA-1 signature:
#   patched  = 31 47 cd 68 66 09 ea c5 54 a0 47 76 4e 1c ac 76 29 4b ca ae 3b f8 77 81
#   original = 36 cc f9 11 85 50 21 90 d3 07 51 95 eb e9 10 6f 5d 7b ed 2d 54 2b
```

Details and the full investigation: **[docs/VFS-REDIRECT.md](docs/VFS-REDIRECT.md)**.

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
| **Flashed on a *different* device?** | The jar is firmware specific. The module applies it unconditionally (there is no automatic fallback to the stock SDK), so on a different firmware the camera may misbehave instead of silently cancelling captures. Use `./install.sh` — it rebuilds the patch from *that* device's own SDK. |
| **After a ColorOS OTA** | The redirect keeps serving the module's jar, so the camera keeps working — it just runs the older SDK. If the camera misbehaves after an OTA, rebuild with `./install.sh` (the new SDK is picked up automatically). The module deliberately does **not** step aside: falling back to the stock SDK would silently disable every capture. |

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
| `chcon` / `setfattr` / `setenforce` from a **boot-time** script | same MKP panic. **This module therefore sets the SELinux label exactly once, at install time**; its boot scripts only create one `mount --bind` and the NoMount redirect rules. |
| Bind-mount over `/product/...` with the wrong label | the camera app cannot read the jar → `NoClassDefFoundError`, instant crash. The jar (and the copy NoMount redirects to) keeps the `system_file` label the original had. |

> Note: on this device MKP also panics continuously from unrelated modules
> (`zygisk_vector`, `rezygisk`, …). If `dmesg | grep policy_action_panic` is
> already counting up while the patch is disabled, that is **not** the patch.

### Requirements

* **KernelSU** (or KernelSU Next) with the **NoMount** metamodule
  (`id=nomount`, v2.1+) — that is the kernel VFS redirect the SDK jar is
  delivered through. The module detects it and tells you if it is missing.
* No reboot-loop risk from mounts: the module creates **one** bind mount (the
  bootclasspath thermal jar) through an inode-checked `bind_once()` with a hard
  cap of 4. There is no mount loop anywhere.

### The module's own safety rails

| Guard | What it prevents |
|---|---|
| the patched jar must be complete (recorded size) | redirecting to a truncated / half-written file |
| the effective path is **re-checked every 10 s** (`stat -Lc %s` = our size, vdex = 0) | a lost redirect silently running the stock SDK |
| the user is **notified** when the redirect cannot be repaired | a silent "shutter does nothing" |
| inode-checked `bind_once()` + hard mount cap | stacking mounts (a development build once filled the table and crashed the phone) |
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
install.sh                   patch both jars + install + reboot  (device side)
uninstall.sh                 rollback
ksu-module/
  module.prop                KernelSU module metadata
  post-fs-data.sh            NoMount redirect rules + the thermal bind mount
  service.sh                 redirect watcher (repairs + notifies) + volume-key
                             switch + camera-spin watchdog
  boot-completed.sh          keeps the watcher alive, final verification
  product/framework/…        the redirect tree NoMount injects at boot
  sepolicy.rule              lets the camera write its private log to /data/vendor
tools/
  patch_sdk.py               applies the three fixes to a decoded smali tree
  dexfp.py                   dex reader: inventory / fingerprint / compare
  analyze_sdk_skew.py        finds API skew between an APK and the device SDK
  build_release.sh           packages the flashable module zip
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
