# Troubleshooting

Error signatures seen on the OnePlus Nord 3 (CPH2491) and what each one
actually means. All of them are reproduced from the camera's own private log
(`/data/vendor/cam_alog_*.txt`) and from `logcat`.

---

## 1. "takePicture, not allow take picture"

```
E CameraUnit, ProducerImpl: takePicture, not allow take picture,
    mbApsFinishAddFrame: true, isApsCaptureAlgoInitializing: false, checkResult: 0, isCShot: false
E OCAM_ApsService: onCaptureFailed
E OCAM_CaptureProcessor: onApsCaptureFailed, capture: 1
W OCAM_CaptureProcessor: completeCapture, capture: 1, success: false
```

**Meaning:** the capture was cancelled by the AI/APS gate.

**Gate** (`ProducerImpl.takePicture()`):

```java
if (mode.isAllowedToTakePicture(...) != 0)  -> allowed
if (mode.isNeedAPSProcess()) {                // hard-coded true in the stock SDK
    if (consumer.isApsCaptureAlgoInitializing())  -> allowed
}
if (mbApsFinishAddFrame || mbBurstShot)        -> allowed
-> otherwise: "not allow take picture"
```

**Gotcha:** the values printed in the log are **re-read at log time**, so
`isApsCaptureAlgoInitializing: false` in the message does **not** mean it was
false when the branch was taken. The branch that fired is the one where it was
still *true* — which it always is on this firmware, because the APS stack can
never initialise (missing `/odm/lib64` AI libraries).

**Fix:** patch 2 and 3 of the module (`isNeedAPSProcess() → false` and the
capture gate).

**How to confirm the APS really cannot run:**

```bash
adb shell su -c 'grep -i "dlopen failed\|not found" /data/vendor/cam_alog_*.txt | tail'
# /odm/lib64/libImplicitWatermark.so dlopen failed ... not found
# odm/lib64/libai_perception_scene_detect.so not found!
# /odm/lib64/libUpScale.so failed ... not found
# /odm/lib64/libarcsoft_hdr_denoise_api_v4.so failed ... not found
```

---

## 2. `java.lang.ClassCastException: long[] cannot be cast to int[]`

```
java.lang.ClassCastException: long[] cannot be cast to int[]
    at com.oplus.ocs.camera.producer.mode.BaseMode.updateCaptureRequestTag(BaseMode.java:1957)
    at com.oplus.ocs.camera.producer.ProducerImpl.takePicture(ProducerImpl.java:849)
```

**Meaning:** camera app **6.070.215 or newer** stores the capture parameter
`com.oplus.picture.exif.flag` as a `long[]`; the 6.020.980-era CameraUnit SDK
reads it back with a hard `(int[])` cast.

**Fix:** patch 1 of the module. The stock 6.020.980 app is unaffected.

---

## 3. The camera's private log spins (this one kills the camera)

```
E/APS_ALOG: Failed to open directory
E/APS_ALOG: Unable to open file. Please disable SELinux and restart camerahalserver. !!!
E/APS_ALOG: CAM_ALOG_LIMIT, re-create file!
E/APS_ALOG: FileALogWriter: file open failed /data/vendor/cam_alog_2026_10_21_210247_28436_01.txt
```

**Meaning:** `persist.sys.camera.private.log.enable=true` is set, but the
camera app is not allowed to write `/data/vendor` by this firmware's SELinux
policy. The writer retries in a **tight loop** — measured **~3000 log lines
per second** — which:

* pegs one CPU core (measured: 306 s of CPU in 5 minutes of uptime),
* floods and wraps the logcat buffer (other logs get dropped),
* and eventually gets the camera process killed.

That is exactly the "the camera works for a while, then it does not" symptom:

```
20:55:57.480 I/ActivityManager: Death received, pid = 24355, processName = com.oplus.camera
20:55:57.491 I/ActivityManager: Process com.oplus.camera (pid 24355) has died: svcb SVC
20:56:27.476 I/ActivityManager: Start proc 28436:com.oplus.camera/u0a155 for service {...ApsService}
```

**Fix:** the module ships `ksu-module/sepolicy.rule` with the two rules that
let the camera write there. Applied live it takes the camera process from
100 % CPU to 0 % and the log rate from ~3000/s to 1 per 3 s.

**Emergency fix without the module:**

```bash
adb shell su -c 'setprop persist.sys.camera.private.log.enable false'
adb shell su -c 'am force-stop com.oplus.camera'
```

Turning the private log off is always safe — it only costs you diagnostics.

---

## 4. The camera opens but the preview is black / the HAL is unhappy

```
D/AppAISHUTTERME(2842): Wrong segBufSize!!! expected(24576), received(0)
```

This comes from `camerahalserver` (not from the app): the app is supposed to
hand the HAL a 24576-byte "AI shutter metadata" buffer and hands it over
empty. It is a **symptom**, not the cause — the buffer stays empty because the
AI scene-detection engine never runs. Fixing the APS gate (issue 1) makes it
go away.

---

## 5. The patch is installed but the camera still cancels every capture

Check that the **zygote** namespace really has the patched jar:

```bash
adb shell su -c 'nsenter -t $(pidof zygote64) -m -- md5sum /product/framework/com.oplus.camera.unit.sdk.jar'
adb shell su -c 'md5sum /data/adb/modules/ocam_sdkfix/SDK-PATCHED.jar'
```

The two hashes must be identical. If they are not, the mount lost the race
against the zygote — see the mount-namespace section in the README.

Then check that the running app really loaded the patched classes (the dex
signature in memory, section "The mount-namespace trap" in the README). If the
app still shows the *original* signature, restart it:

```bash
adb shell su -c 'am force-stop com.oplus.camera'
```

---

## 6. Things that are **not** the cause

| Symptom | Reality |
|---|---|
| `MKP_ERR: check_selinux_state:509: selinux_state is not matched` / `do_policy_action_panic for policy:2` | MediaTek MKP kernel-integrity module panicking continuously (measured 480–825/min). Unrelated to the camera; there is no userland fix, it needs a boot-image repack. **Do not** try to `rmmod mkp` — that kernel-panics. |
| `AIUnit-Plugin-DetectEngine: runByByte onFailed.` | The AI unit is failing its inference because it gets the *real* thermal values. That is intentional: the AI unit must see the real temperature. Do not patch `com.oplus.aiunit`. |
| `NoSuchMethodError: getCreatedUserIdList()` in `com.oplus.notificationmanager` | A version skew between `com.oplus.notificationmanager` and `oplus-framework.jar`. Roll the notification manager back to the factory `16.99.17.19`; it crashed 129×/day with the newer one. |
| `setenforce 0` / frida as a "fix" | **Never.** MKP hashes the SELinux state and panics the kernel. |
