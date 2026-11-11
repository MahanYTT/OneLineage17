#!/system/bin/sh
# Return to One UI / Safe State Restoration
BACKUP_DIR="/data/local/tmp/lineage_backups"

echo "=== [1/5] Terminating Container Supervision & Zygote ==="
pkill -9 -f "ctl.stop zygote" 2>/dev/null || true
pkill -9 -f "kill -STOP" 2>/dev/null || true
pkill -9 -f "ui_activator" 2>/dev/null || true
pkill -9 -f "zygote_exec" 2>/dev/null || true
# Stop the adb watchdog started by switch_to_lineage.sh before One UI's own
# system_server comes back, so it cannot fight init over sys.usb.config.
pkill -9 -f "adb_watchdog.sh" 2>/dev/null || true
pkill -9 -f "key_escape.sh" 2>/dev/null || true
pkill -9 -f "getevent -lq" 2>/dev/null || true
pkill -9 -f "ims_watchdog.sh" 2>/dev/null || true
# Thermal safety valve (switch_to_lineage.sh). If it capped the CPUs and was
# then killed, put the original cpufreq limits back so One UI is not left slow.
pkill -9 -f "thermal_guard.sh" 2>/dev/null || true
if [ -f /data/local/tmp/lineage_stage/thermal_cpufreq.saved ]; then
    while read -r f v; do
        [ -n "$f" ] && [ -n "$v" ] && echo "$v" > "$f" 2>/dev/null
    done < /data/local/tmp/lineage_stage/thermal_cpufreq.saved
    rm -f /data/local/tmp/lineage_stage/thermal_cpufreq.saved
    echo "Restored cpufreq limits capped by the thermal guard"
fi
pkill -9 -f "crashloop_guard.sh" 2>/dev/null || true
pkill -9 -f "boot_watchdog.sh" 2>/dev/null || true
pkill -9 -f "data_tripwire.sh" 2>/dev/null || true
pkill -9 -f "lineage_diag.sh" 2>/dev/null || true
# The session logcat writer (switch_to_lineage.sh): stop it so One UI's logs
# do not rotate Lineage's out of /data/local/tmp/takeover_logcat.log*.
pkill -f "takeover_logcat.log" 2>/dev/null || true
# The data tripwire freezes and stops One UI's installd when it fires.
kill -CONT $(pidof installd) 2>/dev/null
setprop ctl.start installd 2>/dev/null
# Host properties that switch_to_lineage.sh changed for the session (dexopt
# throttle, adb tcp port, ...): put the originals back before One UI's
# system_server reads them.
if [ -f /data/local/tmp/lineage_stage/saved_props ]; then
    while IFS='=' read -r k v; do
        [ -n "$k" ] && setprop "$k" "$v" 2>/dev/null
    done < /data/local/tmp/lineage_stage/saved_props
    rm -f /data/local/tmp/lineage_stage/saved_props
    echo "Restored host properties changed for the Lineage session"
fi
# Stop the suppressors started by switch_to_lineage.sh so One UI's own
# media.codec and rescue_boot_count handling is restored.
pkill -9 -f "media_codec_suppress" 2>/dev/null || true
pkill -9 -f "rescue_boot_suppress" 2>/dev/null || true
pkill -9 -f "system_server" 2>/dev/null || true
pkill -9 -f org.lineageos 2>/dev/null || true
pkill -9 -x zygote64 2>/dev/null || true
pkill -9 -x zygote_next 2>/dev/null || true
kill -9 $(pidof surfaceflinger) 2>/dev/null || true

# Everything still running in Lineage's mount namespace (recorded by
# switch_to_lineage.sh at launch) or any child namespace unshared by Lineage's
# zygote (which have /postinstall in their mounts from pivot_root) goes before
# One UI starts. Without this, orphaned zygote children (webview_zygote,
# com.android.nfc, apps...) survive the return, keep running in One UI, and
# hold the session loop devices open. Never our own or init's namespace.
STAGE_DIR=/data/local/tmp/lineage_stage
GUEST_NS=$(cat "$STAGE_DIR/guest_mnt_ns" 2>/dev/null)
# Only trust it when it was written since this boot (namespace ids are
# reused after a reboot).
BOOT_T=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
[ "$(stat -c %Y "$STAGE_DIR/guest_mnt_ns" 2>/dev/null || echo 0)" -gt "$BOOT_T" ] 2>/dev/null || GUEST_NS=""
n=0
HOST_NS=$(readlink /proc/1/ns/mnt 2>/dev/null)
SELF_NS=$(readlink /proc/self/ns/mnt 2>/dev/null)
for d in /proc/[0-9]*; do
    p=${d#/proc/}
    [ "$p" = "$$" ] && continue
    pns=$(readlink "$d/ns/mnt" 2>/dev/null)
    [ "$pns" = "$HOST_NS" ] || [ "$pns" = "$SELF_NS" ] && continue
    if [ -n "$GUEST_NS" ] && [ "$pns" = "$GUEST_NS" ]; then
        kill -9 "$p" 2>/dev/null && n=$((n + 1))
    elif grep -q " /postinstall" "$d/mounts" 2>/dev/null; then
        kill -9 "$p" 2>/dev/null && n=$((n + 1))
    fi
done
echo "Stopped $n processes left in Lineage's namespaces"
rm -f "$STAGE_DIR/guest_mnt_ns"

# Lineage's vold took over the binder name "vold" from One UI's vold (which
# kept running). Stop it, then let voldkeeper (started by switch_to_lineage.sh)
# register One UI's vold as "vold" again before One UI's system_server starts:
# otherwise it cannot commit the userdata checkpoint and the phone reboots
# ("reboot,checkpoint_commit_failed"). Only a vold that is not one of the PIDs
# recorded before the session AND lives in another mount namespace than One
# UI's vold is killed.
HOST_VOLDS=$(cat "$STAGE_DIR/host_vold_pids" 2>/dev/null)
if [ -n "$HOST_VOLDS" ]; then
    set -- $HOST_VOLDS
    HOST_VOLD_NS=$(readlink "/proc/$1/ns/mnt" 2>/dev/null)
    for p in $(pidof vold); do
        case " $HOST_VOLDS " in *" $p "*) continue ;; esac
        ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
        if [ -n "$HOST_VOLD_NS" ] && [ -n "$ns" ] && [ "$ns" != "$HOST_VOLD_NS" ]; then
            kill -9 "$p" 2>/dev/null && echo "Stopped Lineage vold (pid $p)"
        fi
    done
fi
if [ "$(cat "$STAGE_DIR/vold_keeper.state" 2>/dev/null)" = held ]; then
    touch "$STAGE_DIR/vold_restore"
    i=0
    while [ $i -lt 40 ] && [ "$(cat "$STAGE_DIR/vold_keeper.state" 2>/dev/null)" = held ]; do
        sleep 0.25; i=$((i + 1))
    done
    echo "vold keeper: $(cat "$STAGE_DIR/vold_keeper.state" 2>/dev/null)"
fi
pkill -9 -f "voldkeeper hold" 2>/dev/null || true
rm -f "$STAGE_DIR/vold_restore"

# Put the host's own /data trees back FIRST: master_prepare.sh bridges the
# staged app trees (installd/artd write there), and the One UI launcher restore
# below must read the host's real /data/user/0, not the guest's.
for d in app app-staging user user_de dalvik-cache misc/profiles; do
    umount "/data/$d" 2>/dev/null || true
done

echo "=== [2/5] Restoring One UI Home Screen Layout & Permissions ==="
LAUNCHER_PKG="com.sec.android.app.launcher"
LAUNCHER_DATA="/data/user/0/$LAUNCHER_PKG"
LAUNCHER_UID=$(stat -c %u "$LAUNCHER_DATA" 2>/dev/null || echo 10160)
LAUNCHER_GID=$(stat -c %g "$LAUNCHER_DATA" 2>/dev/null || echo 10160)

if [ -d "$BACKUP_DIR" ] && [ -d "$LAUNCHER_DATA/databases" ]; then
    cp -a "$BACKUP_DIR"/* "$LAUNCHER_DATA/databases/" 2>/dev/null || true
    chown -R ${LAUNCHER_UID}:${LAUNCHER_GID} "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 771 "$LAUNCHER_DATA/databases" 2>/dev/null || true
    chmod 660 "$LAUNCHER_DATA/databases"/* 2>/dev/null || true
    echo "One UI Home screen database restored with UID $LAUNCHER_UID:$LAUNCHER_GID"
fi

echo "=== [3/5] Unmounting Container Overlays ==="
# Make the rootfs tree private before unmounting anything: its binds of One
# UI's /apex/* may still be peers of the host mounts, and unmounting a peer
# unmounts One UI's APEX too (apexd fails, init reboots the phone with
# "reboot,apexd-failed").
mount --make-rprivate /data/local/tmp/lineage_stage/rootfs 2>/dev/null || true
# Unmount only real mount points under the rootfs, deepest first. Never
# glob it: the image's /system_ext and /product are absolute symlinks
# (-> /system/system_ext ...), umount follows them, and
# "umount -l rootfs/*" unmounted One UI's own /system_ext and /product. One
# UI's system_server then crash-looped ("vendor.qti.hardware.trustedui-V1-ndk.so
# not found") until bootchecker rebooted the phone
# (rescueparty_by_bootchecker R2); reproduced on an S26 Ultra.
ROOTFS_DIR=/data/local/tmp/lineage_stage/rootfs
n=0
while [ $n -lt 20 ]; do
    MPS=$(awk -v r="$ROOTFS_DIR" '$2 == r || index($2, r "/") == 1 { print $2 }' /proc/mounts | sort -r)
    [ -z "$MPS" ] && break
    for m in $MPS; do umount -l "$m" 2>/dev/null; done
    n=$((n + 1))
done
# Status bar overlays copied into One UI's resource cache for Lineage.
rm -f /data/resource-cache/com.android.shell-ol_sb*-olsb.frro /data/resource-cache/*ol_sb*-olsb.frro@idmap 2>/dev/null
BB=$(which busybox 2>/dev/null || echo /data/adb/ksu/bin/busybox)
if [ -x "$BB" ]; then
    # Every loop device of the session (image, APEX payloads, fake FRP):
    # left attached, each session needed new loop numbers.
    for l in $($BB losetup -a | grep "/data/local/tmp/lineage_stage/" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
fi

echo "=== [4/5] Restoring Storage Mounts ==="
umount -l /storage/emulated 2>/dev/null || true
umount -l /mnt/user/0/emulated 2>/dev/null || true
mkdir -p /storage/emulated/0
mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true

echo "=== [5/5] Starting One UI Display & Host Services ==="

# Reset battery statistics. The guest system_server writes its own BatteryStats
# while it runs, and those values survive into One UI where they manifest as
# "1% battery" / "charging" false-positive on the first One UI boot after a
# Lineage session. Dumping and clearing before One UI starts avoids that.
dumpsys batterystats --reset 2>/dev/null || true
rm -f /data/system/batterystats.bin 2>/dev/null || true

# Reset biometric enrollment state. The Lineage FingerprintService writes to
# /data/system/users/0/fpdata and /data/vendor_de/0/fpdata during a session. If
# the guest enrolls or queries fingerprints those writes can corrupt the Samsung
# TrustZone biometric DB, and the fingerprint sensor stops responding in One UI.
# Force the fingerprint HAL to re-sync from TrustZone on next One UI boot.
setprop ctl.stop vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.stop vendor.biometrics.fingerprint.inscreen 2>/dev/null || true
sleep 1
setprop ctl.start vendor.fingerprint-default-1_0 2>/dev/null || true
setprop ctl.start vendor.biometrics.fingerprint.inscreen 2>/dev/null || true

setprop ctl.start surfaceflinger
# Lineage 24 (Android 17) already took the DNS resolver's one-time
# getUnstableInterface() call (see netd_restart in switch_to_lineage.sh);
# One UI's system_server needs a fresh netd to get it again.
if [ "$(cat /data/local/tmp/lineage_stage/guest_sdk 2>/dev/null || echo 36)" -ge 37 ] 2>/dev/null; then
    case "$(cat /data/local/tmp/lineage_stage/netd_restart 2>/dev/null | tr -d ' \t\r\n')" in
        0|off|false|no) ;;
        *) setprop ctl.restart netd 2>/dev/null; sleep 1; echo "netd restarted for One UI" ;;
    esac
fi
# Keep Samsung's rescue counter at 0 until One UI has fully booted again.
# Every zygote restart during the handover bumps sys.rescue_boot_count and
# restarts bootchecker ("on property:init.svc.zygote=restarting"); at 5 it
# reboots with "rescueparty_by_bootchecker R2", and higher levels prompt to
# wipe app data. The switch's rescue_boot_suppress loop (stopped above) did
# this during the session; this one ends once dev.bootcomplete has been 1
# for a minute, or after 10 minutes.
setprop sys.rescue_boot_count 0 2>/dev/null; setprop crashrecovery.rescue_boot_count 0 2>/dev/null
nohup sh -c ': rescue_boot_settle
t=0; ok=0
while [ $t -lt 600 ] && [ $ok -lt 60 ]; do
    setprop sys.rescue_boot_count 0 2>/dev/null; setprop crashrecovery.rescue_boot_count 0 2>/dev/null
    [ "$(getprop dev.bootcomplete)" = 1 ] && ok=$((ok + 5))
    sleep 5; t=$((t + 5))
done' </dev/null >/dev/null 2>&1 &
setprop ctl.start zygote
setprop ctl.start zygote_next 2>/dev/null || true
setprop ctl.start audioserver
setprop ctl.start cameraserver
# switch_to_lineage.sh stops the host media codec stack (its IMediaCodecList AIDL
# hash does not match the GSI's, which spins the guest's MediaCodecList); bring it
# back for One UI.
# Lineage's own mediaserver (started by master_inner.sh) must go before One
# UI's "media" service can register media.player again.
kill -9 $(pidof mediaserver) 2>/dev/null || true
for svc in media media.extractor media.codec mediametrics wificond; do
    setprop ctl.start $svc 2>/dev/null || true
done
am force-stop com.sec.android.app.launcher 2>/dev/null || true
am start -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null || true

# switch_to_lineage.sh drops SELinux to permissive for the takeover; restore it.
setenforce 1 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"
echo "One UI restored successfully."
