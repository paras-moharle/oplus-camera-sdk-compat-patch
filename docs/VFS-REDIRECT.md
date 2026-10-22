# How the patched SDK is delivered (VFS redirect, not a mount)

**Short version:** a bind mount can never reach the camera app on this firmware.
The patched `com.oplus.camera.unit.sdk.jar` is delivered as a **kernel VFS path
redirect** (NoMount metamodule), which is independent of mount namespaces.

---

## 1. The symptom that started this

After a cold boot the camera silently ran the **stock** SDK again and cancelled
every capture (`CF_APS_FINISH_ADD_FRAME`), even though:

* `post-fs-data.sh` had mounted the patched jar,
* `stat` in the init namespace showed the patched file,
* `stat` inside the camera's own namespace also showed the patched file.

No error anywhere. The shutter just did nothing.

## 2. What was actually happening

### 2.1 Every app process gets a *fresh* mount namespace

```
init  (mount pf → /product/framework, jar → …/com.oplus.camera.unit.sdk.jar)
 │
 ├── zygote64     ← HAS the mounts (inherited from init)
 │     │
 │     └── com.oplus.camera   ← does NOT have them
 │           mount 7582: 0:72  /  /product/framework   (the OEM OverlayFS only)
```

Measured on the device:

```
$ grep product/framework /proc/$(pidof zygote64)/mountinfo
695 688 0:72  / /product/framework  … master:29
697 695 254:63 /adb/modules/ocam_camfix/pf /product/framework …
698 697 … empty.bin …/com.oplus.camera.unit.sdk.vdex
699 697 … empty.bin …/com.oplus.camera.unit.sdk.odex

$ grep product/framework /proc/$(pidof com.oplus.camera)/mountinfo
7582 7575 0:72 / /product/framework … master:29      <- only the overlay
```

The app namespace is created by the kernel/module stack at process
specialisation time and **all module mounts are removed from it** (KernelSU's
`kmount` feature and the Zygisk *denamespace* step both exist to hide modules
from apps). Mounts created later — even as root, even with `nsenter` into the
app namespace — are useless: ART extracts `classes.dex` from the jar at process
start, before anything can be mounted.

Measured mounts that were *not* visible in the app namespace, one by one:

| Attempt | Result in the app |
|---|---|
| bind in init namespace | invisible |
| bind in zygote namespace | invisible |
| bind in the app's own namespace (`nsenter`) | visible to `stat`, **too late** for ART |
| bind over the overlay's lowerdir root (`/mnt/vendor/my_product/product_overlay/framework`) | invisible |
| replace the whole overlay with a plain directory (`pf`), rebuilt every boot | invisible |

### 2.2 OverlayFS pins the lowerdir dentry

`/product/framework` is an OverlayFS:

```
overlay /product/framework … lowerdir=/mnt/vendor/my_product/product_overlay/framework/:/product/framework/
```

OverlayFS resolves the lowerdir **once, when the overlay is mounted**, and keeps
that dentry. A later mount over the lowerdir path (`/mnt/vendor/...`) or over
the merged path is therefore never seen by a lookup that goes through the
overlay. That is why `stat` could show the patched file while the app still
mapped the stock one:

```
71c4a52000-71c4f05000 r--p 00000000 fe:04 84572928  /product/framework/com.oplus.camera.unit.sdk.jar
72c48f6000-72c4905000 rw-p 00000000 fe:04 77162874  /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex
```

`fe:04` is the **read-only erofs** device that the overlay's first lowerdir
lives on — i.e. the stock jar and the OEM's prebuilt dexopt artifacts, not our
files.

## 3. The mechanism that works: a kernel VFS path redirect

This device runs **NoMount** (`/data/adb/modules/nomount`, `nm`), a metamodule
that replaces MagicMount with VFS path redirection in a small kernel module.
`nm rule add <virtual> <real>` makes *every* path lookup of `<virtual>` resolve
to `<real>`, in **every mount namespace**, with no mount at all.

The module ships the redirect tree:

```
/data/adb/modules/ocam_camfix/
├── SDK-PATCHED.jar
└── product/framework/
    ├── com.oplus.camera.unit.sdk.jar                 # patched (4 946 456 bytes)
    └── oat/arm64/
        ├── com.oplus.camera.unit.sdk.vdex            # empty
        └── com.oplus.camera.unit.sdk.odex            # empty
```

NoMount's `metamount.sh` walks every module's `product/` tree **at boot, before
the zygote and before any app**, and injects these rules:

```
/product/framework/com.oplus.camera.unit.sdk.jar
    -> /data/adb/modules/ocam_camfix/product/framework/com.oplus.camera.unit.sdk.jar
/product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex
    -> /data/adb/modules/ocam_camfix/product/framework/oat/arm64/…vdex   (0 bytes)
/product/framework/oat/arm64/com.oplus.camera.unit.sdk.odex
    -> …/…odex                                                           (0 bytes)
```

The **empty** odex/vdex matter: the OEM ships prebuilt artifacts **compiled from
the stock jar**. If ART finds them it never reads the jar at all — that was the
second half of the silent-stock problem. The zero-length files force ART to
extract the dex from the patched jar.

`post-fs-data.sh` adds the same rules again (idempotent — a repeated `nm rule
add` replaces the rule) and verifies them.

### 3.1 The rule must be created with the overlay visible

NoMount hijacks the VFS operations of the **parent directory inode** (its
dmesg shows `hijacked VFS ops for parent dir (ino: 2)` and
`Superblock successfully hijacked for dev: 0x48`). If the rule is added while a
bind mount of ours covers `/product/framework`, the hijack lands on *that*
mount (a different superblock) and has no effect on the app's overlay.

That is why the module **no longer mounts anything over `/product/framework`**.
At boot the path is the OEM overlay, so the hijack is applied to the overlay
superblock — the same superblock the app namespace uses.

## 4. Verified result

```
$ stat -Lc %s /product/framework/com.oplus.camera.unit.sdk.jar
4946456                     # 4 926 415 = stock

$ stat -Lc %s /product/framework/oat/arm64/com.oplus.camera.unit.sdk.vdex
0

$ grep camera.unit.sdk /proc/$(pidof com.oplus.camera)/maps
71c482d000-71c4ce5000 r--p 00000000 00:00 0  [anon:dalvik-classes.dex extracte... /product/framework/com.oplus.camera.unit.sdk.jar]
```

`[anon:dalvik-classes.dex extracted from jar: …]` is the goal: ART extracted the
dex **from our jar**. A line ending in the plain path `…/com.oplus.camera.unit.sdk.jar`
means the redirect is missing and the stock jar is in use — with it a file
inode on `fe:04` (erofs) instead of `00:00 0`.

Photos taken after this change: `IMG20261022090821.jpg` (2.27 MB, 3072×4096).

## 5. Redundancy and automatic recovery (24/7)

The redirect lives in the kernel module's rule table, which is re-created at
every boot. Three layers keep it alive:

| Layer | When | What it does |
|---|---|---|
| NoMount `metamount.sh` | boot, before the zygote | injects the rules from the module's `product/` tree |
| `post-fs-data.sh` | boot, before the zygote | re-adds the rules, verifies them, drops a stale `/data/dalvik-cache` entry |
| `service.sh` watcher | twice a second for the first minute, then every 10 s | `stat` the OEM path; if it is not our jar (or the prebuilt vdex is not masked) re-apply the rules. If a camera process was running while the redirect was broken it is force-stopped so it reloads the patched classes, and the user is notified |
| `boot-completed.sh` | last boot stage | restarts the watcher if it is not running, otherwise notifies that the fix is inactive |

If the redirect **cannot** be repaired, the user gets a notification instead of
a silent "shutter does nothing".

## 6. Things that will still break it (and what to do)

| Event | Effect | Recovery |
|---|---|---|
| NoMount (or the whole KernelSU stack) removed/disabled | no redirect; camera uses the stock SDK | the module notifies; reinstall NoMount + reboot |
| `nm rule clear` / NoMount reloaded at runtime | rules gone | the watcher re-adds them within 10 s (camera auto-restarted) |
| ColorOS OTA replaced the SDK jar | the redirect still points to **our** jar, so nothing changes — but the jar may now be stale | rebuild from the new jar with `./install.sh` |
| The module dir was deleted but the LKM kept the rules | the camera loads a missing path → `ClassNotFound` | reboot (rules are not persistent) |
