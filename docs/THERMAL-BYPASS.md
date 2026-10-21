# The 3–6 second shutter — camera thermal bypass (`ocam_thermalfix`)

**Optional module.** Only needed if your camera takes photos but they arrive
**several seconds** after you press the shutter, the preview is choppy, or
video recording is refused when the phone is warm.

---

## The symptom

* Pressing the shutter does nothing visible for **3–6 seconds**, then the
  photo appears.
* The preview stutters.
* Starting a video fails with a "high temperature" complaint when the phone
  has been warm for a while.
* Present on **both** the newer camera (6.070.215) and the stock one
  (6.020.980).
* Present on a **stock ROM** as well — it is not caused by root.

## Root cause

Both camera APKs hard-code the capture temperature threshold:

```smali
# camera 6.070.215 : smali_classes4/qc/a2.smali
# camera 6.020.980 : smali_classes2/ka/m1.smali
const-string v2, "41"        # common_capture_temperature_threshold
const-string v4, "43"        # portrait_capture_temperature_threshold
```

and compare it against the skin temperature reported by Oplus' *horae* thermal
service:

```
$ dumpsys horae | head -3
Temp: 41.53
ThrottlingLevel: 0
TempDataCollection: { "b40": 10, "b41": 9, "b42": 5, "b43": 0, ... }
```

A phone whose skin sits at **40.4–44 °C** (the vendor's own thermal HAL
actively holds the skin at its 44 °C target) is therefore *permanently* above
that threshold, so the camera's capture-defer logic stays engaged:

* every capture is deferred (3–6 s instead of ~1 s),
* the preview is degraded (`CODE_CAMERA_HIGH_TEMPERATURE_OUT_PREVIEW_DISABLE`),
* video is refused (`tryRecord fail, high temperature, thermalLevel:`).

The threshold **cannot** be changed by configuration — the OEM code fills a
map keyed by the *label string* but looks it up with the *enum object*, so the
lookup always misses and the hard-coded default is always used:

```smali
# qc/s.smali  (fill)                # qc/s.smali  (read)
invoke-virtual {v5}, ->getLabel()   invoke-virtual {v0, p0}, ConcurrentHashMap;->get(...)
invoke-virtual {v6, v5, v7}, ->put   invoke-virtual {p0}, Lqc/a2;->getValue()   # -> "41"
```

and the config file it would read,
`/odm/etc/camera/config/oplus_camera_feature_config`, does not exist on this
firmware anyway.

> This is **not** classic CPU thermal throttling: during a camera session the
> big cores still run at 1.7–2.0 GHz and the machine is ~80 % idle. The camera
> is simply being told it is too hot.

## The fix

Patch the framework that owns the temperature source:

```
/system/framework/oplus-framework.jar
  com/oplus/util/OplusHoraeThermalHelper
    getCurrentThermal()F   -> real skin temperature
    getThermalStatus()I    -> real horae level
```

For the **camera process only** (uid detected from the device) they return
**two different values, on purpose** — they pull in opposite directions:

| method | value returned | what the camera does with it |
|---|---|---|
| `getCurrentThermal()` | **30.0 °C** (low) | compared against the camera's own capture threshold (**41 °C**). Below it → the capture is **not deferred** → no 3–6 s shutter |
| `getThermalStatus()` | **13** (high) | `max(config, status) >= 13` in `hb/u.W1()` → "too hot" → the camera **does not use the AI/EAP (APS multi-frame) capture path** |

The second one is the subtle part. The AI/EAP capture path is **broken on this
firmware** (the `aisubsystem` stack never completes → `onCaptureFailed` →
`CF_APS_FINISH_ADD_FRAME` → *every* capture is rejected, no photo at all).
Reporting a *low* status makes the camera insist on that broken path — so the
status has to be reported **high** while the temperature is reported **low**.

```smali
    invoke-static {}, Landroid/os/Process;->myUid()I
    move-result v0
    const/16 v1, 0x27ab            # uid of com.oplus.camera
    if-eq v0, v1, :ocam_thermal_bypass
    goto :ocam_no_thermal_bypass
    :ocam_thermal_bypass
    const/high16 v0, 0x41f00000    # getCurrentThermal() -> 30.0f
    return v0
    :ocam_no_thermal_bypass
    # ... and in getThermalStatus():
    :ocam_thermal_bypass_status
    const/16 v0, 0xd               # getThermalStatus() -> 13
    return v0
```

The **AI unit (`com.oplus.aiunit`) is deliberately not patched** — it must keep
seeing the real thermal state, otherwise its own inference refuses to run
(`AIUnit-Plugin-DetectEngine: runByByte onFailed`).

## How it is deployed

* The jar is **bind-mounted** over `/system/framework/oplus-framework.jar`; the
  file on disk is never modified.
* The mount must happen **before the zygote starts** — it opens the bootclasspath
  at boot. Measured on the Nord 3: the module's `post-fs-data.sh` runs at
  **t = 10 s** and `init: starting service 'zygote'` happens at **t = 11.7 s**,
  so the patched jar is the one the zygote loads.
* The SELinux label is set **once, at install time**, copied from the original
  (`u:object_r:system_file:s0`). The zygote must be able to read the jar, or
  the phone boot-loops.
* The boot scripts do **nothing but** a guarded `mount --bind`, and every path
  `exit 0` — they can never fail a boot.
* A sha256 guard makes the module refuse to mount on a different firmware
  (e.g. after an OTA).

### How to check it is actually live

The zygote holds the bootclasspath jar open — check *which* file, and follow
the symlink (`stat -L`, otherwise you stat the `/proc/.../fd/N` link itself
and get a meaningless inode):

```bash
z=$(pidof zygote64 | cut -d' ' -f1)
fd=$(ls -l /proc/$z/fd | grep oplus-framework.jar | head -1 | awk '{print $8}')
stat -Lc '%d:%i' /proc/$z/fd/$fd          # what the zygote has open
stat -Lc '%d:%i' /data/adb/modules/ocam_thermalfix/PATCHED-ofw.jar
# both must be identical -> the patched jar is the one in memory
```

## Install

```bash
# together with the SDK patch
./install.sh --with-thermal-fix

# or on its own
./install_thermalfix.sh

# or flash the prebuilt zip
#   release/ocam_thermalfix-v1.0.zip
#   KernelSU Manager -> Modules -> Install from storage -> reboot
```

Build it yourself for another device:

```bash
adb pull /system/framework/oplus-framework.jar
tools/build_framework_patch.sh oplus-framework.jar     # decode, patch, rebuild, verify
tools/build_thermalfix_zip.sh release/thermal/patched-ofw.jar \
                            release/thermal/original-ofw.jar
```

Verify:

```bash
adb shell mount | grep oplus-framework       # patched jar bound in
adb shell ls -Z /system/framework/oplus-framework.jar   # u:object_r:system_file:s0
dumpsys horae | grep Temp                     # real value, unchanged for other apps
```

Rollback:

```bash
./uninstall.sh --thermal
```

## Verification performed

| Check | Result |
|---|---|
| Patched jar loaded in a real ART process (`app_process` probe) | ✅ `currentThermal=30.0 status=0` |
| Same jar, non-camera uid | ✅ real values `40.38 / 7` — no side effects elsewhere |
| Class inventory vs. original jar | ✅ identical (6443 + 995 classes) |
| Method inventory vs. original jar | ✅ identical (65106 + 7295 methods) |
| Dex magic / size / adler32 / sha1 | ✅ valid for both dex files |
| Bind mount + SELinux label | ✅ mounted, `system_file` |
| System health with the mount active | ✅ camera launches, HAL receives `isCapture(1)` |
| Mount precedes the zygote | ✅ `post-fs-data` at t=10 s, zygote at t=11.7 s |
| Zygote holds the patched jar | ✅ identical `device:inode` to `PATCHED-ofw.jar` |

### Measured result on the Nord 3

| | before | after |
|---|---|---|
| Tap → photo on disk | 3.2 – 6.3 s | **0.89 s** |
| skin / horae temperature at the time | 44 – 49 °C / 43 – 45 °C | 49 °C / **45.4 °C** |
| camera crashes | 0 | 0 |

The "after" shot was taken while the phone was **4.4 °C above** the camera's
own 41 °C threshold — i.e. the deferral no longer triggers even when the
device is hot. Both numbers come from the same scene and the same lighting on
the same phone (the AE/exposure values in the logcat are identical).

## Relationship to the SDK patch

The two modules are independent and solve different problems:

| | `ocam_sdkfix` | `ocam_thermalfix` |
|---|---|---|
| Problem | camera 6.070.215 takes **no photo** at all | camera takes photos, but takes **3–6 s** and feels laggy |
| Cause | `ClassCastException` on the exif flag (`long[]` vs `int[]`) | capture temperature threshold 41 °C vs. a phone that idles at 41–44 °C |
| Fix | patched `com.oplus.camera.unit.sdk.jar` | patched `oplus-framework.jar` (camera uid only) |
| Needs | camera ≥ 6.070.215 on a 6.020.980-era SDK | any Oplus camera on any firmware |

## ⚠️ MediaTek MKP warning

Never add `chcon` / `setfattr` / `setenforce` to a **boot-time** script:
MediaTek's MKP kernel-integrity module hashes the SELinux state and panics the
kernel (kernel panic, boot loop) when anything SELinux-related changes while
the system is booting. The label is set once, at install time.
