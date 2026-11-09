# Changes to test (2026-11-08)

Written for the OneLineage17 fork running on a Galaxy S26 Ultra (One UI 9 /
Android 17), but most of it applies to any device OneLineage supports.

## WARNING: LineageOS 24 (Android 17) deleted user data

**Cause (proven from the session log):** at boot Lineage logged `PackageManager: Destroying user 0 on volume null because we failed to prepare` (twice), plus 194 `Failed to create app data ... but trying to recover`. Lineage's system_server uses **One UI's installd** (pid 2532 in the io_stats lines, the process doing the reads and ~186 GB of discards), so `UserDataPreparer.destroyUserDataLI` -> `installd.destroyUserData(0)` wiped the real user 0 app data (/data/user/0, /data/user_de/0) and media (/data/media/0). Lineage then asked for a factory reset (RecoverySystemService wrote the BCB). The /data "bridge" binds were meant to point installd at Lineage's folders, but they are made from a KernelSU shell, whose mount namespace One UI's installd may not share.

**Guards now required for any Android 17 guest** (master_prepare.sh refuses to start otherwise):
- services17_patched.jar (tools/dexpatch/services17.txt, 74 patch points): Installer isolated (no installd calls at all), no user/storage destroy, no vold key/storage prepare, no keystore super-key or Weaver use, no FRP writes, no recovery/BCB/factory reset.
- service-art17_patched.jar (tools/dexpatch/service-art17.txt): no artd cleanup/delete calls.
- Private /data/media for the guest (share_media=1 to opt in), no /data bridges, read-only /data/adb and /data/apex.
- Data tripwire (switch_to_lineage.sh): canaries in the real /data/user/0, /data/user_de/0, /data/media/0 and the /data/user/0 entry count, checked every second; on a hit it freezes installd, kills Lineage and blocks further starts ($STAGE/tripwire_fired).
Verified offline: both jars pass dex2oat verification; tripwire dry run trips ~1 s after a canary is removed; master_prepare refuses with a guard missing.

## Device results (2026-11-08, S26 Ultra, launched from adb as in 0.A)

| Item | Result | Evidence |
|---|---|---|
| Thermal guard zone choice | **Fixed, verified** | `cpu-hw-trip-0/1` always read 105 C (trip points). The guard tripped 4 s after start, ran return_to_oneui.sh during master_prepare.sh, pivot_root failed, phone stuck on the Samsung boot screen. Zones matching `trip\|limit` are now skipped; Lineage boots. |
| Heat (CPU caps) | **Verified** | One UI's SSRM is gone in Lineage; a core went 45 -> 105 C in ~30 s. Baseline 70 % cap + 50 % at 85 C for 4 s: caps read back on both policies, hottest core ~58-65 C after boot. |
| system_server busy loop | **Fixed, verified** | `CaptureStateTracker: Audio policy service died` ~6,700 lines/s -> 0 after patching `ExternalCaptureStateTracker.run()` in services_patched.jar. |
| Remaining CPU and the ~30 min freezes | **Fixed, verified** | Lineage read its codec list from One UI's Android 17 mediaserver (`media.player`) and looped in `MediaCodecList::findMatchingCodecs -> BpMediaCodecList::getCodecInfo -> MediaCodecInfo::FromParcel`: mediaserver ~140 %, system_server and SystemUI ~120 % each, and both grew >100 MB/min of native heap until "Scudo ERROR: internal map failure (Out of memory)" after ~30 min. Now One UI's mediaserver is stopped and Lineage's own runs (`guest_mediaserver`). Result: top processes a few %, hottest core ~40 C, system_server ~400 MB and SystemUI ~300 MB flat over several minutes. Media playback still to be checked. |
| adb over USB | **Open** | Every adb service over USB hangs 1-2 min after boot (even `adb reboot`); usb.state never changes. adbd itself is healthy: a thread snapshot shows only normal waits, and **adb over Wi-Fi keeps working** while USB is stuck, so the stall is in the USB path. Restarting adbd or re-enumerating the gadget does not bring USB back. Hiding adbd's control socket from Lineage did not help (now an opt-in experiment, `adb_framework_block`). |
| adb over Wi-Fi | **Verified, use this** | `echo 5555 > $STAGE/adb_tcp`, then `adb connect <phone-ip>:5555` (key auth still applies). Survives the USB stall. |
| Volume-key escape | **Verified** | Hold Volume Up + Down 3 s -> return_to_oneui.sh; worked on the phone with adb dead. |
| Status bar / cutout | **Fixed, verified** | Root cause: One UI's Android 17 idmap2d serves Lineage's overlay requests and cannot build idmaps for it (`failed to parse idmap header`), so no runtime overlay applied. `fix_frro_idmaps` copies the `.frro` files into Lineage's /data and builds idmaps with Lineage's own idmap2, then restarts SystemUI. Result: cutout `Rect(680, 0 - 760, 139)`, status bar 139 px, icons clear of the hole. Same fix covers SystemUI's wallpaper-colour overlays (not checked visually). |
| Internet | Works (user report) | Wi-Fi and mobile data both work; mobile "a bit weird". |
| LineageOS 24 (Android 17) GSI | **In progress, not booting yet** | Stage `system.raw` = lineage-24.0 arm64_bvN (ext4, SDK 37); 23.2 kept in `$STAGE/backup_l23` (image, payloads, data). master_prepare.sh reads the image SDK and skips every Android 16 patch (services/framework jars, preloaded-classes, audio libs, framework-res, PermissionController) for SDK >= 37. |
| Zygote on Android 17 (`zygote_exec17`) | **Verified** | zygote_exec has the Android 16 class paths built in. master_inner.sh runs the image own derive_classpath and execs the new launcher (Rust, tools/zygote_exec17), which takes them from the environment. Log: `SDK 37: class paths from /apex/com.android.sdkext/bin/derive_classpath`, zygote starts. |
| Android 17 boot blockers | **Fixed one by one, verified** | 1. `createProcessGroup(1000, 0) failed` -> host cgroup tree bound (guest_cgroups auto-on for SDK 37). 2. `Invalid feature flag: android.security.aapm_...` -> private /metadata/aconfig built from the image own flag files (guest_aconfig, 34 containers). 3. `jniClatCoordinator: lstat /sys/fs/bpf/net_shared` -> host /sys/fs/bpf bound. 4. `Cannot open uid permission map` -> One UI Tethering APEX used (host_apex). 5. `Signature mismatch ... android.uid.networkstack` -> One UI NetworkStackGoogle and CellBroadcast APEX too (host_apex = tethering cellbroadcast). 6. `IDnsResolver.getUnstableInterface: Already called by AID_SYSTEM` -> netd restarted at switch and return (netd_restart). 7. `Failed to protect CE key for user 0` (One UI vold refuses a new key) -> lock-settings state (locksettings.db, spblob) copied from the 23.2 data, done by hand on the phone. 8. `Creating a ClassLoader from .../service-lifeguard.jar is not allowed` -> Samsung LifeGuard APEX bound. 9. `Failed to protect CE key` / Weaver slot 0 / `Failed to initialize Keystore super keys for user 0` -> services17_patched.jar: no vold key changes, no Weaver, no keystore super-key init/lock/unlock/reset (all One UI's). 10. `FRP is active` writing One UI's FRP partition -> private fake FRP loop (guest_fake_frp). **Result: system_server stays up, user 0 RUNNING_LOCKED (not unlocked yet).** |
| Reboot after leaving Lineage | **Fixed (3 causes), return not re-tested yet** | 1. `reboot,apexd-failed`: the media suppressor killed the updatable `mediametrics` (wrong ctl name); init set sys.init.updatable_crashing and the next apexd start rebooted. Now stopped through init. 2. `rescueparty_by_bootchecker R2`: **return_to_oneui.sh ran `umount -l rootfs/*`; the image /system_ext and /product are absolute symlinks, umount followed them and unmounted One UI's own /system_ext and /product** (reproduced: host lib gone right after that line). One UI system_server then crash-looped (`vendor.qti.hardware.trustedui-V1-ndk.so not found`) until bootchecker rebooted. Now only real mount points from /proc/mounts are unmounted. 3. Rescue counters (sys. and crashrecovery.rescue_boot_count) are held at 0 until One UI has booted. |
| Google app | Open | Crashes when anything enumerates cameras (WebView VideoCaptureFactory): `CameraMetadataNative ... Failed to read from parcel (error code -22)`. Android 17 cameraserver metadata vs Android 16 framework. |
| GMS | Mostly OK | Crash-loops only in the first ~7 s of boot (CronetDynamite.apk writable, SafetyCenter AdvancedProtection), then stable. |
| Shell root | Note | After every reboot or return to One UI, Shell root must be re-granted in KernelSU-Next before `adb shell su` works. |

The sections below were written before any device run.
Every change below was written from
reading the scripts. CI checks it offline: syntax under mksh/busybox/dash,
shellcheck, LF line endings, zygote_exec integrity, and unit tests that run the
watchdog logic against fake sysfs/props. CI says nothing about how the phone
behaves. Each new behaviour can be switched off with a file in
`/data/local/tmp/lineage_stage/` ("`$STAGE`" below). No APK rebuild is needed
to switch one off.

## 0. Getting the new scripts onto the phone

**A. Fastest, no APK rebuild.** `switch_to_lineage.sh` only copies files from
the app into `$STAGE` when they are missing there, so files you push yourself
are kept:

```bash
adb push assets/switch_to_lineage.sh assets/return_to_oneui.sh assets/master_prepare.sh assets/master_inner.sh /data/local/tmp/
```

```bash
adb shell su -c 'cp /data/local/tmp/switch_to_lineage.sh /data/local/tmp/return_to_oneui.sh /data/local/tmp/master_prepare.sh /data/local/tmp/master_inner.sh /data/local/tmp/lineage_stage/ && chmod 755 /data/local/tmp/lineage_stage/*.sh'
```

Then start Lineage from adb instead of the app's Switch button. Do not open
the OneLineage app after pushing: when it starts, and again when you tap
Switch, it copies its bundled (old) scripts over `$STAGE`.

```bash
adb shell su -c 'setsid sh /data/local/tmp/lineage_stage/switch_to_lineage.sh </dev/null >/data/local/tmp/lineage_stage/takeover_app.log 2>&1 &'
```

**B. Download a build.** Every push to `main` publishes an APK at
<https://github.com/MahanYTT/OneLineage17/releases/latest>. It is signed with a
CI key, so uninstall any other OneLineage build first, or the installer fails
with "Couldn't install". Or repack the APK yourself with the four `.sh` files
(see HANDOFF.md, "Build and test"); git checks them out with LF line endings.

Replace `su -c` with however you normally get a root shell.

## 1. Thermal safety valve (test first, it protects the hardware)

What: `thermal_guard.sh` watches the cpu/gpu thermal zones and the battery.
85 C for 20 s: CPUs are capped to 70 %. 95 C for 30 s, 103 C for 6 s, or
battery 47 C for 60 s: it runs `return_to_oneui.sh` by itself and posts a
notification in One UI.

Proof:
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh status'
```
`thermal_guard: running` should appear, plus the hottest zones. Then:
```bash
adb shell su -c 'cat /data/local/tmp/thermal_guard.log'
```
The first line lists the zones it chose (`zones: cpu-... gpuss-...`). If it
says `WARNING: no thermal zone matched`, check `lineage_ctl.sh temps` and
set `thermal_zones` to a regex that matches your zone names.

Safe trip test (no real heat needed): lower the trip point below the current
temperature, then wait ~30 s. The phone should return to One UI by itself, and
`$STAGE/thermal_tripped` and a notification should appear:
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh set thermal_trip_c 40'
```
That flag is only read when the guard starts (and again every ~30 s), so it
takes effect without restarting. Afterwards set it back:
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh unset thermal_trip_c'
```
Off switch: `lineage_ctl.sh set thermal_guard 0`, or `log` for a dry run.

## 2. Setup wizard skip

What: marks the guest provisioned and disables the GMS/Lineage/AOSP setup
wizards in the guest only, before HOME starts.

Proof: Lineage boots straight to the launcher. Then:
```bash
adb shell su -c 'grep -E "wizard|provisioned|SafetyCenter" /data/local/tmp/ui_activator.log'
```
Expect `device marked provisioned, setup wizard skipped`.
Undo: `lineage_ctl.sh wizard-restore`.

## 3. Heat: what is burning CPU now

These run together. The first proof is whether the phone is cooler. Check
`lineage_ctl.sh status` (temps + top CPU users) 5 and 15 minutes after boot,
and compare with the ~105 C from before.

| Change | Proof | Off switch |
|---|---|---|
| GMS SafetyCenter disabled early, DeviceConfig sync frozen | `ui_activator.log` has `SafetyCenter API disabled for GMS`; `adb logcat -b crash -d \| grep -c "Unexpected safety source"` stops growing; `crashloop_guard.log` has no `GMS still hits SafetyCenter` | `gms_safety_fix 0` |
| Crash-loop guard (disables looping non-core apps in the guest) | `lineage_ctl.sh logs` → `crashloop_guard.log`; `lineage_ctl.sh crashloop-list` | `crashloop_guard 0` / `log`; undo with `crashloop-undo` |
| Storage sweep only on install (was ~1500 forks / 10 s) | `top` no longer shows a constant stream of `stat`; installing an app from Play still makes it launchable within ~10 s | `storage_sweep_full 1` |
| Dexopt throttle (host props, restored on exit) | `adb shell getprop pm.dexopt.disable_bg_dexopt` = `true` while in Lineage and back to the old value after return; no `dex2oat` in `top` | `dexopt_throttle 0` |
| Idle at 60 Hz instead of forced 120 Hz | `adb shell su -c 'cat /data/local/tmp/lineage_display.txt'` shows `min_refresh_rate=60.0` | `min_refresh 120.0` |
| Guest cgroups + app freezer (**opt-in, off**) | Turn on only after the rest is confirmed: `lineage_ctl.sh set guest_cgroups 1`, Switch again, then the display report shows files under `/sys/fs/cgroup` | `guest_cgroups 0` |

If it is still hot: run `lineage_ctl.sh status` while hot. The "top CPU
users" part, and the `thermal_guard.log` lines starting `top CPU users:`,
show what to go after next (include them when opening an issue).
The guard records them each time it reaches the soft limit.

## 4. Wi-Fi / internet spinner (DNS heal)

What: the old heal toggled Wi-Fi every 90 s, and every toggle created a new
network with the same ~30 s DNS gap. The new one sets DNS for the current
netId with `ndc` and never toggles Wi-Fi unless `net_bounce=1`.

Proof:
```bash
adb shell su -c 'cat /data/local/tmp/lineage_stage/data/app_storage.log'
```
You may see `dns heal: netId N ... names resolve again`. You should not see
repeated `wifi bounced` lines. Settings > Network should show Wi-Fi as
connected without "no internet", and Play Store should load.
If `still failing` repeats: `lineage_ctl.sh set dns_servers 1.1.1.1,8.8.8.8`.
If that also fails, the `ndc:` part of those lines shows what netd answered.
Off: `dns_heal 0`. Old behaviour as last resort: `net_bounce 1`.

## 5. ADB

What: the watchdog checks every 1 s (was 3 s) and logs every USB state change.
adb over Wi-Fi is opt-in.

Proof: `cat /data/local/tmp/adb_watchdog.log` after a drop shows exactly
when `usb.state` changed and what it was rewritten to.
Wi-Fi fallback (needs a Switch after setting it):
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh set adb_tcp 5555'
```
After Lineage is up, `lineage_ctl.sh status` prints the `wlan0` address, then:
```bash
adb connect PHONE_IP:5555
```
It uses the PC's existing adb key, so no pairing is needed. `return_to_oneui.sh`
restores the port setting.

## 6. Status bar size: needs your eyes

Nothing was changed blindly. What is needed to fix it properly:
1. a screenshot of Lineage's status bar with the shade pulled down, and
   one of One UI for comparison;
2. the output of `adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh display'`.

Try these live while you are at it (no reboot):
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh density 500'
```
```bash
adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh fontscale 0.9'
```
The bar height probably follows the camera cutout (~139 px), not the density.
If the bar is too tall, the next step is a cutout/status-bar-height overlay,
and the report gives the values to use.

## 7. Repo hygiene

- `.gitattributes`: `zygote_exec` is now `binary`. It was `text eol=lf`,
  which allows end-of-line rewriting inside an ELF.
- CI: `.github/workflows/scripts.yml` runs `tests/run_all.sh` on every push.
  Run it locally with `sh tests/run_all.sh` (needs mksh, busybox, dash and
  shellcheck).

## All toggles

`adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh flags'` prints every
toggle with its value and default. Most toggles are read at Switch time. The
exceptions are the thermal guard thresholds (re-read every ~30 s), `dns_heal`,
`dns_servers` and `net_bounce` (read every 10 s; `lineage_ctl.sh set` also
updates the guest's copy), and `density`/`fontscale` through `lineage_ctl.sh`
(applied immediately).
