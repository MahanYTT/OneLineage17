# OneLineage17 hand-off: overheating, setup wizard hang, status bar size

> **Update 2026-11-08 (cloud session, nothing tested on the device):** the patches for
> all four problems are on `main`, one commit per problem, and each can be switched off
> with a file in `/data/local/tmp/lineage_stage/`. **Start with
> [CHANGES_TO_TEST.md](CHANGES_TO_TEST.md)**, which is ordered by risk and gives the exact
> commands. `/data/local/tmp/lineage_ctl.sh` (written at Switch) shows status and flips
> toggles. CI (`tests/run_all.sh`) checks syntax, line endings and the watchdog logic offline.
> What changed from the plan below, and why:
> - The `safety_center_is_enabled` flag is kept, not replaced. Android 16's
>   `setSafetySourceData` checks "API enabled" *before* it validates the source id, so the
>   flag should work. The old code just set it too late (~45 s in) and let GMS sync it back.
> - Not done: freezing GMS components, or swapping in MindTheGapps' GMS. The first needs
>   component names we don't have; the second is a downgrade that can break GMS databases.
>   The crash-loop guard logs whether the SafetyCenter crash still happens.
> - `persist.sys.usb.config` is left alone. AOSP UsbDeviceManager parses it at start and
>   does not know Samsung's `sec_charging` function. adb over Wi-Fi (`adb_tcp`) is the fallback.
> - Found by reading the scripts: `ensure_app_storage.sh` forked ~1500 `stat` every 10 s;
>   `min_refresh_rate` was forced to 120 Hz; the DNS heal flushed a hard-coded netId 100,
>   and its hostname-ping check misread networks that drop ICMP as broken DNS;
>   `zygote_exec` was marked `text` in `.gitattributes`.
> - Status bar: no resource change without a screenshot. A diagnostics report and live
>   density/fontscale knobs were added instead.

Repo: https://github.com/MahanYTT/OneLineage17 (fork of WeWaffles/OneLineage), branch `main`.
Owner's own phone, own fork, own LineageOS image. Nothing here is third-party or untrusted.

## IMPORTANT: what a cloud session can and cannot do
- The phone (Galaxy S26 Ultra, SM-S948B, One UI 9 = Android 17, SDK 37, Snapdragon 8 Elite "canoe")
  is connected by USB to the owner's Windows PC. A cloud session has NO ADB access.
- So: do static analysis of the scripts, write careful patches, push to `main`.
  Do NOT claim anything is verified. Mark every change "untested on device".
- Make every new behaviour toggleable via a file in `/data/local/tmp/lineage_stage/` (like the
  existing `density` file) so the owner can switch it off without rebuilding.
- Never commit private data: no device serial, Wi-Fi SSID, accounts, tokens, keystores, logs.
  `git log -p | grep -i -E "serial|ssid|password|token"` before pushing.
- Shell scripts MUST have LF line endings (`.gitattributes` enforces it). CRLF in
  `assets/master_inner.sh` previously caused a black-screen boot failure.
- `assets/zygote_exec` and `*.jar` are binaries. Never text-normalize them.

## How the project works (read these files first)
- `assets/switch_to_lineage.sh`: host-side launcher. Starts adb/ims watchdogs, a rotating logcat,
  `ui_activator.sh` (waits for the guest system_server, then applies settings), then unshares a
  mount namespace and runs `data/master_inner.sh`.
- `assets/master_prepare.sh`: builds the guest rootfs from `system.raw` (a LineageOS 23.2 /
  Android 16 GSI + MindTheGapps) and loop-mounts the GSI's APEX payloads. Also writes
  `net_fix.sh` and `app_storage_loop.sh`.
- `assets/master_inner.sh`: pivot_root into the guest, starts wificond, then `zygote_exec`.
- The guest (Android 16 userspace) runs on the host's live Samsung kernel, vendor HALs and host
  daemons (servicemanager, netd, audioserver...). It shares `/data` with One UI.
- Build: the owner repacks an existing APK with the `assets/` files and signs it with
  uber-apk-signer (`build_apk.sh` is the from-source route). See "Build" below.

## State at hand-off (verified earlier tonight over ADB)
- Lineage boots fully: `sys.boot_completed=1`, no service start failures.
- Density override works: `wm density 540` applied by `ui_activator.sh` (host panel is 1440x3120,
  native 600 dpi = 384 dp wide, now sw427dp).
- Logcat recorder is capped (4 MB x 3). It used to be an unbounded 14 GB file.
- Commits up to `6521ac8` are on `main`.

## Open problems (the owner reports these after boot)
1. **Phone overheats badly** (a thermal zone read ~105 C, battery ~44 C) and ADB drops.
2. **Setup wizard / "internet" loads forever** after the owner connected Wi-Fi in setup.
3. **Status bar / notification shade size is still off** (even after the 540 dpi change).
4. ADB over USB is lost shortly after Lineage is up (seen twice).

### 1. Heat: leading hypotheses (rank, then patch the cheap safe ones)
- Host Google Play Services is the **Android 17 build** in `/data/app`. In the guest it crash-loops
  every ~5 s with `IllegalArgumentException: Unexpected safety source: AdvancedProtection` at
  `SafetyCenterManager.setSafetySourceData` (Android 16 SafetyCenter rejects the new source).
- Zygote runs with `-Xforcejitzygote` and the guest has no matching odex/oat (host
  `/data/dalvik-cache` is compiled for Android 17 ART), so every respawn JIT-compiles everything
  from scratch on all 8 cores. Also check for background dexopt / `bg-dexopt-job` storms after
  first boot and for app-compilation of every host-installed app (the owner has ~200 apps).
- `ui_activator.sh` currently runs `device_config put privacy safety_center_is_enabled false`.
  This is probably NOT enough: Android 16 may validate the source id before checking enabled.
  Better options to evaluate: disable/freeze `com.google.android.gms` crash-looping components in
  the guest only (without touching One UI's package state; check whether guest and host share
  `/data/system/packages.xml` and `/data/system/users`), install the guest's own MindTheGapps
  GMS over the host copy, or rate-limit with `am set-standby-bucket` / `cmd appops` /
  `cmd activity` freezer (`cmd activity set-freezer` / `settings put global cached_apps_freezer enabled`).
- Throttle first-boot work: `cmd package bg-dexopt-job` cancel, `pm compile -m verify`
  instead of speed profiles, `settings put global ...` to limit background processes, disable
  heavy host-only apps in the guest (Samsung services that spin because the Samsung framework is
  missing: look for any process pegging CPU; the owner can run `top -b -n1 -H` in the guest).
- Guest has no working thermal HAL session? Check `android.hardware.thermal` and
  `/data/local/tmp/lineage_stage/data` for thermal logs; the Samsung kernel throttles on its own,
  so the real fix is reducing load, not thermal config.
- Add a **safety valve**: a host-side watchdog (like `adb_watchdog.sh`) that reads
  `/sys/class/thermal/thermal_zone*/temp` and, if any zone stays above ~95 C for N seconds, runs
  `return_to_oneui.sh` automatically. Make it toggleable. This protects the owner's hardware.

### 2. Setup wizard / internet spinner
- Evidence: guest NetworkMonitor reported `PROBE_DNS ... ENONET (Machine is not on the network)`
  right after boot and after each Wi-Fi network re-creation (netId 100 -> 104...), recovering only
  after ~30 s; apps got `Unable to resolve host`. Root cause is probably that the guest's
  ConnectivityService registers netIds with the host netd (Android 17) via an AIDL/Binder boundary
  that doesn't fully work, so the resolver for the new netId isn't ready.
- Existing mitigations in `net_fix.sh` (routing table 4242 + a DNS self-heal that flushes the
  resolver and bounces Wi-Fi at most every 90 s). Re-read that logic critically: bouncing Wi-Fi
  every 90 s may itself cause new network ids and endless re-validation, i.e. the spinner.
  Consider instead: `ndc network create`/`ndc resolver setnetdns <netId> ...` for the current
  netId, or setting a fixed private resolver, instead of toggling Wi-Fi.
- Make the setup wizard skippable automatically (flag file, default on):
  `settings put global device_provisioned 1`, `settings put secure user_setup_complete 1`,
  and disable the GMS/AOSP setup wizard packages (`com.google.android.setupwizard`,
  `com.android.provision`, `org.lineageos.setupwizard`) from `ui_activator.sh` before the
  launcher starts. A stuck wizard also burns CPU while it spins.

### 3. Status bar / notification shade size
- Host cutout: top inset 139 px at density 3.75 (host 600 dpi) = about 37 dp. At the new
  540 dpi (3.375) that same 139 px cutout is about 41 dp, bigger than the default 24 dp bar, so
  the bar is built from the cutout height, which looks "off". Candidates: `config_statusBarHeight`
  / `status_bar_height_default` / `quick_qs_offset_height` via a runtime resource overlay (RRO)
  on `android` and `com.android.systemui`, or `wm overscan`/cutout override
  (`cmd overlay enable com.android.internal.display.cutout.emulation.*` or
  `settings put secure display_cutout_mode`/`device_config`), or `ignore-cutout`.
- Ask the owner for a screenshot; do not guess which direction "off" means.
  `wm density` is read from `$STAGE/density` (default 540). Tune that value first.
- The 600 dpi vs 450 relationship: host reports `ro.sf.lcd_density=600`, `.default=450`
  (450 dpi at 1080 px wide = 384 dp, same as 600 at 1440 px).

### 4. ADB loss
- Lineage's `UsbDeviceManager` rewrites `sys.usb.config`; `adb_watchdog.sh` now maps bare `adb` to
  `sec_charging,adb`. It still dropped under heavy load. Consider also forcing
  `setprop persist.sys.usb.config` / re-asserting every 1 s while the temp is high, and enabling
  wireless debugging as a fallback (needs one-time pairing on the phone).

## Build and test (owner does this; for reference)
1. Repack the installed APK: replace `assets/{clean_apex_info_list.xml,master_prepare.sh,
   master_inner.sh,switch_to_lineage.sh,return_to_oneui.sh,zygote_exec,framework_patched.jar,
   preloaded-classes}` byte-for-byte (convert CRLF to LF for `.sh`/`.xml` only), sign with
   uber-apk-signer, `adb install -r`.
2. Re-arm temp-root (`s25uroot`), open OneLineage, tap Switch. `return_to_oneui.sh` returns to
   One UI without a reboot. If the screen is black and ADB is up, `adb reboot` recovers.
3. Useful logs (root-owned): `/data/local/tmp/lineage_stage/data/takeover.log`,
   `/data/local/tmp/takeover_logcat.log*`, `/data/local/tmp/ui_activator.log`.

## Deliverable
Push small, separate commits to `main` (one per problem), each with a comment block in the script
explaining the evidence and how to disable it. End with a short `CHANGES_TO_TEST.md` listing, per
change, the exact command or screenshot that would prove it works, so the owner can test in the
morning in order of risk (safety valve and wizard skip first).
