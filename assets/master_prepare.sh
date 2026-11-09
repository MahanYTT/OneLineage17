#!/system/bin/sh
STAGE="/data/local/tmp/lineage_stage"
ROOTFS="$STAGE/rootfs"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")

# Filesystem of an image file, from its magic bytes: LineageOS 23.2 (Android
# 16) images and APEX payloads are ext4, Android 17 builds may use erofs.
img_fstype() {
    if [ "$($BB dd if="$1" bs=1 skip=1024 count=4 2>/dev/null | $BB od -An -tx1 | tr -d ' \n')" = "e2e1f5e0" ]; then
        echo erofs
    else
        echo ext4
    fi
}
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

# Disable kernel softlockup and hung-task panics for the duration of the
# container boot. The APEX extraction and pivot_root chain can stall a CPU for
# many seconds (especially on A35/M35 Exynos where the hardware is slow and the
# kernel's softlockup threshold is 100 s). Without this the kernel panics and
# reboots before the container even finishes mounting. These are written back to
# their default (1) by nothing — a hard reboot resets them — so this is safe.
echo 0 > /proc/sys/kernel/softlockup_panic 2>/dev/null || true
echo 0 > /proc/sys/kernel/hung_task_panic 2>/dev/null || true

echo "=== 1. Ensuring Watchdog Feeder is Active ==="
if ! ps -ef | grep -v grep | grep -q "/dev/watchdog"; then
    echo "Starting watchdog feeder..."
    nohup $BB sh -c "while true; do echo -n 1 > /dev/watchdog 2>/dev/null; sleep 2; done" </dev/null >/dev/null 2>&1 &
fi

echo "=== 2. Creating Loop Device Nodes ==="
for i in $(seq 50 150); do
    minor=$((i * 8))
    rm -f /dev/block/loop$i /dev/loop$i 2>/dev/null || true
    mknod /dev/block/loop$i b 7 $minor
    mknod /dev/loop$i b 7 $minor
done

echo "=== 3. Mounting system.raw if needed ==="
if mount | grep -q "$ROOTFS "; then
    if [ ! -f "$ROOTFS/system/bin/sh" ] || [ ! -f "$ROOTFS/init.environ.rc" ]; then
        echo "Rootfs mount is invalid or stale. Unmounting..."
        while mount | grep -q "$ROOTFS"; do
            $BB umount -l "$ROOTFS" 2>/dev/null || true
            sleep 0.1
        done
    else
        echo "Rootfs already mounted and healthy."
    fi
fi

mkdir -p "$ROOTFS"
if ! mount | grep -q "$ROOTFS "; then
    for l in $($BB losetup -a | grep "system.raw" | cut -d: -f1); do
        $BB losetup -d "$l" 2>/dev/null || true
    done
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$STAGE/system.raw"
    echo "Using LOOP: $LOOP"
    $BB mount -t "$(img_fstype "$STAGE/system.raw")" -o ro "$LOOP" "$ROOTFS"
fi

# Which Android the guest image is. OneLineage was built around LineageOS 23.2
# (Android 16, SDK 36); its patched framework.jar/services.jar/preloaded-classes,
# PermissionController and audio libraries are Android 16 builds and must not be
# mounted over a newer image (e.g. LineageOS 24 / Android 17, SDK 37), whose
# framework already matches One UI 9's Android 17 services.
GUEST_SDK=$(grep -m1 '^ro.build.version.sdk=' "$ROOTFS/system/build.prop" 2>/dev/null | cut -d= -f2)
GUEST_FP=$(grep -m1 -E '^ro.(system.)?build.fingerprint=' "$ROOTFS/system/build.prop" 2>/dev/null | cut -d= -f2)
case "$GUEST_SDK" in ''|*[!0-9]*) GUEST_SDK=36 ;; esac
LEGACY16=0; [ "$GUEST_SDK" -le 36 ] && LEGACY16=1
echo "$GUEST_SDK" > "$STAGE/guest_sdk"
# DATA SAFETY (Android 17+ guests). On 2026-11-09 a LineageOS 24 boot on an
# S26 Ultra logged "Destroying user 0 on volume null because we failed to
# prepare", and One UI's installd (shared over binder) wiped the real user 0
# app data and media. An Android 17 guest only starts with every guard in
# place: services17_patched.jar and service-art17_patched.jar (no installd,
# vold key/storage, keystore, recovery or artd-delete calls, see
# tools/dexpatch/*.txt), a private /data/media, no /data bridges, read-only
# /data/adb and /data/apex, and the host-side tripwire in
# switch_to_lineage.sh. If the tripwire ever fired, it stays refused.
if [ "$LEGACY16" = 0 ]; then
    GUARD_FAIL=""
    [ -f "$STAGE/services17_patched.jar" ] || GUARD_FAIL="$GUARD_FAIL services17_patched.jar-missing"
    [ -f "$STAGE/service-art17_patched.jar" ] || GUARD_FAIL="$GUARD_FAIL service-art17_patched.jar-missing"
    case "$(cat "$STAGE/services17_patch" 2>/dev/null | tr -d ' \t\r\n')" in 0|off|false|no) GUARD_FAIL="$GUARD_FAIL services17_patch-off" ;; esac
    [ -f "$STAGE/tripwire_fired" ] && GUARD_FAIL="$GUARD_FAIL tripwire-fired($(cat "$STAGE/tripwire_fired"))"
    if [ -n "$GUARD_FAIL" ]; then
        echo "REFUSING to start an Android $GUEST_SDK guest, data-safety guards missing:$GUARD_FAIL"
        $BB umount -l "$ROOTFS" 2>/dev/null
        exit 1
    fi
    echo "Android $GUEST_SDK guest: data-safety guards present"
fi
echo "Guest image: SDK $GUEST_SDK ($GUEST_FP), Android 16 patches: $([ $LEGACY16 = 1 ] && echo on || echo off)"
# The extracted APEX payloads (*_payload.img) belong to one image: drop them
# when the image changes so they are re-extracted from the new one.
if [ "$(cat "$STAGE/payload_fingerprint" 2>/dev/null)" != "$GUEST_FP" ]; then
    rm -f "$STAGE"/*_payload.img 2>/dev/null
    echo "$GUEST_FP" > "$STAGE/payload_fingerprint"
    echo "Guest image changed: cleared cached APEX payloads"
fi

mkdir -p "$ROOTFS/postinstall" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" \
    "$ROOTFS/linkerconfig" "$ROOTFS/vendor" "$ROOTFS/odm" "$ROOTFS/vendor_dlkm" \
    "$ROOTFS/mnt" "$ROOTFS/storage" "$ROOTFS/apex" "$ROOTFS/data"

echo "=== 4. Setting up Core System Bind Mounts ==="
mount | grep -q "$ROOTFS/proc " || $BB mount -t proc proc "$ROOTFS/proc"
mount | grep -q "$ROOTFS/sys " || $BB mount -t sysfs sysfs "$ROOTFS/sys"

# Give the guest the host's cgroup v2 tree. Opt-in for Android 16 images,
# ON by default for Android 17+ (LineageOS 24): there zygote aborts when it
# forks system_server ("createProcessGroup(1000, 0) failed: No such file or
# directory", verified on an S26 Ultra), so it cannot boot without it.
# A fresh sysfs mount has an EMPTY /sys/fs/cgroup (submounts are not carried
# over), while the guest's libprocessgroup reads the host init's
# /dev/cgroup_info/cgroup.rc (via the /dev rbind) and expects the cgroup2
# hierarchy there. Without it the cached-app freezer cannot work and
# background task profiles probably fail, i.e. background apps are never
# throttled. Default off because it changes how every guest process is
# scheduled. Enable: echo 1 > $STAGE/guest_cgroups (ui_activator then also
# turns on the cached-app freezer). Off on Android 17+: echo 0 > $STAGE/guest_cgroups
GCG=$(cat "$STAGE/guest_cgroups" 2>/dev/null | tr -d ' \t\r\n')
case "$GCG" in ""|auto) [ "$LEGACY16" = 0 ] && GCG=1 ;; esac
case "$GCG" in
    1|on|true|yes)
        if mount | grep -q " /sys/fs/cgroup " && ! mount | grep -q "$ROOTFS/sys/fs/cgroup "; then
            $BB mount --bind /sys/fs/cgroup "$ROOTFS/sys/fs/cgroup" && echo "Bound host /sys/fs/cgroup into the guest (guest_cgroups=$GCG)"
        fi
        # Same story for the BPF filesystem on Android 17+: the Tethering
        # module's service-connectivity aborts system_server when
        # /sys/fs/bpf/net_shared (programs pinned by One UI's bpfloader) is
        # missing ("jniClatCoordinator: lstat /sys/fs/bpf/net_shared errno=2",
        # verified on an S26 Ultra with LineageOS 24).
        if [ "$LEGACY16" = 0 ] && mount | grep -q " /sys/fs/bpf " && ! mount | grep -q "$ROOTFS/sys/fs/bpf "; then
            $BB mount --bind /sys/fs/bpf "$ROOTFS/sys/fs/bpf" && echo "Bound host /sys/fs/bpf into the guest"
        fi
        ;;
esac

if [ ! -e /dev/binderfs/binder ]; then
    mount -t binder binder /dev/binderfs 2>/dev/null || true
    chmod 666 /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder 2>/dev/null || true
fi

$BB mount --make-rprivate "$ROOTFS" 2>/dev/null || true

if ! mount | grep -q "$ROOTFS/dev "; then
    $BB mount --rbind /dev "$ROOTFS/dev"
    $BB mount --make-rprivate "$ROOTFS/dev"
fi

# Factory reset protection. Lineage's PersistentDataBlockService opens
# ro.frp.pst, which is One UI's real FRP partition, and writes its own lock
# credential handle there. On Android 17 it also aborts system_server
# ("SecurityException: FRP is active ... setFrpCredentialHandle", verified on
# an S26 Ultra). Give the guest a private, zeroed image of the same size on a
# loop device, bound over the partition node in the guest's /dev only
# ($ROOTFS/dev is private), so One UI's FRP data is never touched.
# Off: echo 0 > $STAGE/guest_fake_frp
case "$(cat "$STAGE/guest_fake_frp" 2>/dev/null | tr -d ' \t\r\n')" in
    0|off|false|no) echo "Fake FRP partition disabled (flag): Lineage sees One UI's FRP" ;;
    *)
        FRP_NODE=$(readlink -f "$(getprop ro.frp.pst)" 2>/dev/null)
        if [ -n "$FRP_NODE" ] && [ -b "$FRP_NODE" ]; then
            FRP_SIZE=$(blockdev --getsize64 "$FRP_NODE" 2>/dev/null)
            case "$FRP_SIZE" in ''|*[!0-9]*) FRP_SIZE=524288 ;; esac
            if [ ! -f "$STAGE/fake_frp.img" ] || [ "$(stat -c %s "$STAGE/fake_frp.img")" != "$FRP_SIZE" ]; then
                $BB dd if=/dev/zero of="$STAGE/fake_frp.img" bs="$FRP_SIZE" count=1 2>/dev/null
            fi
            FRP_LOOP=$($BB losetup -a | grep "$STAGE/fake_frp.img" | head -n 1 | cut -d: -f1)
            if [ -z "$FRP_LOOP" ]; then
                FRP_LOOP=$($BB losetup -f)
                $BB losetup "$FRP_LOOP" "$STAGE/fake_frp.img"
            fi
            # Same owner, mode and label as the real node: Lineage's
            # system_server (uid system) opens it ("EACCES" with root:root).
            # ueventd resets a freshly attached loop node to root:root, so let
            # it settle first (master_inner.sh sets the owner once more).
            sleep 1
            chown "$(stat -c %u:%g "$FRP_NODE")" "$FRP_LOOP" 2>/dev/null
            chmod "$(stat -c %a "$FRP_NODE")" "$FRP_LOOP" 2>/dev/null
            chcon "$(ls -Z "$FRP_NODE" | cut -d' ' -f1)" "$FRP_LOOP" 2>/dev/null
            $BB umount -l "$ROOTFS$FRP_NODE" 2>/dev/null || true
            if $BB mount --bind "$FRP_LOOP" "$ROOTFS$FRP_NODE"; then
                echo "Fake FRP partition: $FRP_LOOP over $FRP_NODE ($FRP_SIZE bytes)"
            else
                echo "Fake FRP partition: bind failed"
            fi
        fi
        ;;
esac

mount | grep -q "$ROOTFS/linkerconfig " || $BB mount --rbind /linkerconfig "$ROOTFS/linkerconfig"
mount | grep -q "$ROOTFS/vendor " || $BB mount --bind /vendor "$ROOTFS/vendor"
mount | grep -q "$ROOTFS/odm " || $BB mount --bind /odm "$ROOTFS/odm"
mount | grep -q "$ROOTFS/vendor_dlkm " || $BB mount --bind /vendor_dlkm "$ROOTFS/vendor_dlkm"
# apexd is a HOST daemon: it reports the Samsung apex set (/system/apex,
# /system_ext/apex, /vendor/apex) to the container system_server, which then
# tries to parse those exact paths inside this namespace. Keep the apex
# directories identical to what host apexd sees (an empty tmpfs or the GSI's
# own .capex layout makes PMS abort with "Unable to parse" at boot).
# Note: /system/apex and /system_ext/apex are bound AFTER step 8 so payload
# extraction can read the GSI's own /system/apex and /system/system_ext/apex first.
if [ -d /product/apex ]; then
    if [ ! -d "$ROOTFS/system/product/apex" ]; then
        mkdir -p "$STAGE/product_ov"
        mount | grep -q "$STAGE/product_ov " || $BB mount -t tmpfs tmpfs "$STAGE/product_ov"
        mkdir -p "$STAGE/product_ov/upper/apex" "$STAGE/product_ov/work"
        mount | grep -q "$ROOTFS/system/product " || $BB mount -t overlay overlay -o "lowerdir=$ROOTFS/system/product,upperdir=$STAGE/product_ov/upper,workdir=$STAGE/product_ov/work" "$ROOTFS/system/product"
    fi
    mount | grep -q "$ROOTFS/system/product/apex " || $BB mount --bind /product/apex "$ROOTFS/system/product/apex"
fi
mount | grep -q "$ROOTFS/mnt " || $BB mount --rbind /mnt "$ROOTFS/mnt"
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/services_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/services_patched.jar" "$ROOTFS/system/framework/services.jar"
    echo "Bound services_patched.jar -> $ROOTFS/system/framework/services.jar"
fi
# Android 17 (LineageOS 24) services.jar, patched in LockSettingsService and
# SyntheticPasswordManager (see CHANGES_TO_TEST.md). Lineage's lock settings
# talk to One UI's vold and the phone's Weaver hardware, both owned by One UI:
#   - setCeStorageProtection is a no-op: it asked One UI's vold to re-protect
#     user 0's CE key ("Generating storage key not allowed" -> system_server
#     abort "Failed to protect CE key for user 0"); it must never succeed.
#   - no Weaver (getWeaverService* = null, isWeaverDisabledOnUnsecuredUsers =
#     true): Lineage enrolled its synthetic password into hardware Weaver
#     slot 0, which belongs to One UI.
#   - initKeystoreSuperKeys, lockKeystore, unlockKeystore and resetKeyStore
#     are no-ops: they act on keystore2's user 0 super keys, which are One
#     UI's ("Failed to initialize Keystore super keys for user 0"; resetting
#     them would invalidate One UI's auth-bound keys).
#   - CE storage: LockSettingsService.unlockCeStorage is a no-op and
#     isCeStorageUnlocked (LockSettings + StorageManager) is true; One UI's
#     vold refuses Lineage's secret for user 0 ("Failed to unlock CE storage
#     for unsecured user 0"), and Lineage's /data is plain folders anyway.
#     StorageManagerService.lockCeStorage is a no-op: it would lock One UI's
#     user 0 storage.
# Off: echo 0 > $STAGE/services17_patch
if [ "$LEGACY16" = 0 ] && [ -f "$STAGE/services17_patched.jar" ]; then
    case "$(cat "$STAGE/services17_patch" 2>/dev/null | tr -d ' \t\r\n')" in
        0|off|false|no) echo "services17_patched.jar disabled (flag)" ;;
        *)
            $BB umount -l "$ROOTFS/system/framework/services.jar" 2>/dev/null || true
            $BB mount --bind "$STAGE/services17_patched.jar" "$ROOTFS/system/framework/services.jar"
            echo "Bound services17_patched.jar -> $ROOTFS/system/framework/services.jar"
            ;;
    esac
fi
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/framework_patched.jar" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework.jar" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework_patched.jar" "$ROOTFS/system/framework/framework.jar"
    echo "Bound framework_patched.jar -> $ROOTFS/system/framework/framework.jar"
fi
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/preloaded-classes" ]; then
    $BB umount -l "$ROOTFS/system/etc/preloaded-classes" 2>/dev/null || true
    $BB mount --bind "$STAGE/preloaded-classes" "$ROOTFS/system/etc/preloaded-classes"
    echo "Bound preloaded-classes -> $ROOTFS/system/etc/preloaded-classes"
fi
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudio_aidl_conversion_common_cpp_patched.so" "$ROOTFS/system/lib64/libaudio_aidl_conversion_common_cpp.so"
    echo "Bound libaudio_aidl_conversion_common_cpp_patched.so"
fi
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/libaudioclient_aidl_conversion_patched.so" ]; then
    $BB umount -l "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so" 2>/dev/null || true
    $BB mount --bind "$STAGE/libaudioclient_aidl_conversion_patched.so" "$ROOTFS/system/lib64/libaudioclient_aidl_conversion.so"
    echo "Bound libaudioclient_aidl_conversion_patched.so"
fi
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/framework-res_patched.apk" ]; then
    $BB umount -l "$ROOTFS/system/framework/framework-res.apk" 2>/dev/null || true
    $BB mount --bind "$STAGE/framework-res_patched.apk" "$ROOTFS/system/framework/framework-res.apk"
    echo "Bound framework-res_patched.apk -> $ROOTFS/system/framework/framework-res.apk"
fi

if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk"
    PERM_APK=$(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null | head -n 1)
    if [ -n "$PERM_APK" ]; then
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK"
        echo "Bound PermissionController_patched.apk -> $PERM_APK"
    fi
fi



echo "=== 5. Setting up Isolated Data & Bridges ==="
mkdir -p "$STAGE/data/adb" "$STAGE/data/apex" "$STAGE/data/dalvik-cache/arm64"

# Give the guest the host's authorised ADB keys. The container has no
# AdbDebuggingManager (the guest system_server registers no "adb" service), so a
# guest adbd or wireless-debugging session cannot answer an authorisation prompt;
# pre-seeding the keys is the only way it can accept this machine silently.
# Pre-seed adb_enabled=1 into the guest's settings before its system_server runs.
# The in-boot fix (in fix_app_dirs.sh) only lands once the framework is up, but
# UsbDeviceManager drops the adb USB function within seconds of system_server
# starting -- which is why adb dies right after Lineage boots and macOS stops
# seeing the phone entirely. Writing the XML now keeps the gadget stable through
# the whole boot.
GSET="$STAGE/data/system/users/0/settings_global.xml"
if [ -f "$GSET" ]; then
    if grep -q 'id="adb_enabled"' "$GSET" 2>/dev/null; then
        sed -i 's/id="adb_enabled"\([^>]*\)value="[^"]*"/id="adb_enabled"\1value="1"/' "$GSET" 2>/dev/null
    else
        sed -i 's#</settings>#    <setting id="adb_enabled" name="adb_enabled" value="1" package="android" />\n</settings>#' "$GSET" 2>/dev/null
    fi
    echo "Pre-seeded adb_enabled=1 in guest settings_global.xml"
fi

if [ -f /data/misc/adb/adb_keys ]; then
    mkdir -p "$STAGE/data/misc/adb"
    cp -f /data/misc/adb/adb_keys "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        chmod 640 "$STAGE/data/misc/adb/adb_keys" 2>/dev/null && \
        echo "Copied host adb_keys into the guest /data"
fi
for z in zygote_exec zygote_exec17; do
    if [ -f "$STAGE/$z" ]; then
        cp -f "$STAGE/$z" "$STAGE/data/$z"
        chmod 755 "$STAGE/data/$z"
    fi
done
mkdir -p "$STAGE/data/user/0" "$STAGE/data/user_de/0"
mkdir -p "$STAGE/data/system/users/0" "$STAGE/data/system_de/0/spblob" "$STAGE/data/system_ce/0"
mkdir -p "$STAGE/data/misc/user/0" "$STAGE/data/misc_de/0" "$STAGE/data/misc_ce/0"
mkdir -p "$STAGE/data/anr" "$STAGE/data/app" "$STAGE/data/rollback" "$STAGE/data/incremental"

for pkg in com.android.providers.settings \
           com.android.providers.telephony \
           com.android.phone \
           com.android.systemui \
           com.android.settings \
           com.android.launcher3 \
           com.android.inputmethod.latin \
           com.android.providers.media \
           com.android.providers.downloads \
           com.android.providers.contacts \
           com.android.providers.calendar \
           org.lineageos.lineagesettings \
           com.wewaffles.onelineage; do
    mkdir -p "$STAGE/data/user_de/0/$pkg/databases" \
             "$STAGE/data/user_de/0/$pkg/shared_prefs" \
             "$STAGE/data/user_de/0/$pkg/files/datastore/education" \
             "$STAGE/data/user/0/$pkg/databases" \
             "$STAGE/data/user/0/$pkg/shared_prefs" \
             "$STAGE/data/user/0/$pkg/files"
done

mkdir -p "$STAGE/data/resource-cache"
chmod 771 "$STAGE/data/resource-cache"
chown 1000:1000 "$STAGE/data/resource-cache"

rm -rf "$STAGE/data/data" 2>/dev/null || true
mkdir -p "$STAGE/data/data"

chmod -R 777 "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/anr" "$STAGE/data/data" 2>/dev/null || true
chown -R 1000:1000 "$STAGE/data/system" "$STAGE/data/system_de" "$STAGE/data/system_ce" "$STAGE/data/user" "$STAGE/data/user_de" "$STAGE/data/misc" "$STAGE/data/misc_de" "$STAGE/data/misc_ce" 2>/dev/null || true
chown -R 10109:10109 "$STAGE/data/user_de/0/com.android.inputmethod.latin" "$STAGE/data/user/0/com.android.inputmethod.latin" 2>/dev/null || true

# Create the bluetooth stack's storage before the guest ever starts. The GSI's
# GD stack asserts out of storage_module.cc if it cannot persist bt_config.conf,
# and the staged tree never had this directory, so com.android.bluetooth
# crash-looped every 4 s from early boot. uid 1002 = bluetooth.
mkdir -p "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null
chown 1002:1002 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true
chmod 0770 "$STAGE/data/misc/bluedroid" "$STAGE/data/misc/bluetooth" 2>/dev/null || true

# SELinux labels matter just as much as modes here. Every directory below lives
# under /data/local/tmp, so it is created as u:object_r:shell_data_file:s0. The
# guest's system_server runs in u:r:system_server:s0 (Samsung policy) and is
# denied both read and write on shell_data_file: chmod 777 does not help, because
# the denial is MAC, not DAC. That broke UserManagerService (users/0.xml EACCES),
# EntropyMixer/BatteryStats/PackageWatchdog ("Failed to create directory for
# *.new") and finally the settings provider:
#   SQLiteCantOpenDatabaseException: /data/user_de/0/com.android.providers.settings/databases/settings.db
# Relabel the staged tree the way a real /data is labeled. The host bind mounts
# that live inside this tree (/data/apex, /data/adb, /data/media) are deliberately
# excluded so host data never gets relabeled.
echo "=== 5b. Relabeling staged /data for guest SELinux ==="
$BB chcon u:object_r:system_data_file:s0 "$STAGE/data" 2>/dev/null || true
for d in data/system data/system_de data/system_ce data/user data/user_de \
         data/misc data/misc_de data/misc_ce data/anr data/dalvik-cache \
         data/local data/resource-cache data/app data/rollback data/incremental; do
    [ -e "$STAGE/$d" ] && $BB chcon -R u:object_r:system_data_file:s0 "$STAGE/$d" 2>/dev/null || true
done
for d in "$STAGE/data/user/0" "$STAGE/data/user_de/0"; do
    if [ -d "$d" ]; then
        $BB chcon u:object_r:system_data_file:s0 "$d" 2>/dev/null || true
        $BB chcon -R u:object_r:app_data_file:s0 "$d"/* 2>/dev/null || true
    fi
done
# data/apex (host /data/apex) and data/adb (host /data/adb) are left alone: they
# are the host's own directories bind-mounted in, already labeled correctly, and
# chcon-ing a bind mount would relabel the host's copy.

echo "=== 5c. Fixing staged /data ownership and modes ==="
# The stage tree is created by root under /data/local/tmp, so its top-level
# directories come out root:root 0755. A real /data is system:system 0771, and
# system_server (uid 1000) has to be able to create /data/app/vmdl*.tmp:
#   Failed to prepare session dir: /data/app/vmdl10992519.tmp
# With 0755 root:root that mkdir gets EACCES and *every* install fails, which is
# what "non-system apps / downloads crash" looked like from the outside.
$BB chown system:system "$STAGE/data" 2>/dev/null || true
$BB chmod 0771 "$STAGE/data" 2>/dev/null || true
for d in app app-staging anr dalvik-cache incremental property resource-cache rollback ss system; do
    [ -e "$STAGE/data/$d" ] || mkdir -p "$STAGE/data/$d" 2>/dev/null || continue
    $BB chown system:system "$STAGE/data/$d" 2>/dev/null || true
    $BB chmod 0771 "$STAGE/data/$d" 2>/dev/null || true
done
mkdir -p "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0" 2>/dev/null || true
$BB chown system:system "$STAGE/data/misc" "$STAGE/data/misc/profiles" 2>/dev/null || true
for d in "$STAGE/data/misc/profiles/cur" "$STAGE/data/misc/profiles/ref" \
         "$STAGE/data/misc/profiles/cur/0" "$STAGE/data/misc/profiles/ref/0"; do
    [ -d "$d" ] && $BB chown system:system "$d" 2>/dev/null || true
done

echo "=== 5d. Bridging host /data app trees into the staged /data ==="
# installd and artd are HOST daemons (started by Samsung init, they cannot be
# moved into the container namespace). Left alone they create every app data
# dir, dalvik-cache entry and dexopt profile in the real /data, which the guest
# can never see - so every app process the guest zygote forks dies with:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>:
#   No such file or directory
# ("Failed to attach" / "start timeout" in ActivityManager.) Bind the staged
# equivalents over those host paths for the duration of the session, so those
# daemons write into the guest's data. One UI is not running meanwhile and
# return_to_oneui.sh removes the binds again.
# Android 17 guests never call installd (services17_patched.jar), and these
# binds are made in this shell's mount namespace, which One UI's installd may
# not even see, so they protected nothing. Skipped there.
[ "$LEGACY16" = 0 ] && echo "Android 17 guest: /data bridges skipped" || for d in app app-staging user user_de dalvik-cache misc/profiles; do
    mkdir -p "$STAGE/data/$d" 2>/dev/null || true
    if [ -d "/data/$d" ] && ! mount | grep -q " /data/$d "; then
        $BB mount --bind "$STAGE/data/$d" "/data/$d" 2>/dev/null && echo "Bridged /data/$d -> $STAGE/data/$d"
    fi
done

mount | grep -q "$ROOTFS/data " || $BB mount --bind "$STAGE/data" "$ROOTFS/data"
mount | grep -q "$ROOTFS/data/adb " || $BB mount --bind /data/adb "$ROOTFS/data/adb"
mount | grep -q "$ROOTFS/data/apex " || $BB mount --bind /data/apex "$ROOTFS/data/apex"
if [ "$LEGACY16" = 0 ]; then
    # One UI's /data/adb (KernelSU) and /data/apex: read-only for the guest.
    $BB mount -o remount,bind,ro "$ROOTFS/data/adb" 2>/dev/null
    $BB mount -o remount,bind,ro "$ROOTFS/data/apex" 2>/dev/null
fi
mkdir -p "$ROOTFS/data/media"
# Shared storage. Android 17 guests get their own ($STAGE/data/media) unless
# share_media=1: with One UI's real /data/media bound here, anything the
# guest deletes is deleted on the phone.
if [ "$LEGACY16" = 0 ] && [ "$(cat "$STAGE/share_media" 2>/dev/null | tr -d ' \t\r\n')" != 1 ]; then
    mkdir -p "$STAGE/data/media/0"
    echo "Android 17 guest: private /data/media (share_media=1 to share One UI's)"
else
    mount | grep -q "$ROOTFS/data/media " || $BB mount --bind /data/media "$ROOTFS/data/media" 2>/dev/null || true
fi

echo "=== 5e. Writing per-package data-dir helper ==="
# Apps installed before the /data bridge existed have no CE/DE data dirs in the
# guest tree, and the guest zygote refuses to fork them:
#   Failed to mount /data_mirror/data_de/null/0/<pkg> to /data/user_de/0/<pkg>
# This helper recreates the dirs for every package the guest knows about, with
# the uid PMS reports. switch_to_lineage.sh runs it once the container is up.
mkdir -p "$STAGE/data/local/tmp" 2>/dev/null || true
cat > "$STAGE/data/local/tmp/fix_app_dirs.sh" <<'FIXAPPDIRS'
#!/system/bin/sh
# Create missing CE/DE data dirs (and dexopt profile dirs) for every installed
# package, using the uid PMS reports. Idempotent.
created=0
profile_dirs=0
pkg=""
for tok in $(pm list packages -U 2>/dev/null); do
    case "$tok" in
        package:*) pkg="${tok#package:}"; uid="" ;;
        uid:*)     uid="${tok#uid:}" ;;
        *)         continue ;;
    esac
    [ -n "$pkg" ] && [ -n "$uid" ] || continue
    for d in "/data/user/0/$pkg" "/data/user_de/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0700 "$d" 2>/dev/null
            created=$((created + 1))
        fi
    done
    for d in "/data/misc/profiles/cur/0/$pkg" "/data/misc/profiles/ref/0/$pkg"; do
        [ -d "$d" ] && continue
        if mkdir -p "$d" 2>/dev/null; then
            chown "$uid:$uid" "$d" 2>/dev/null
            chmod 0771 "$d" 2>/dev/null
            profile_dirs=$((profile_dirs + 1))
        fi
    done
    pkg=""; uid=""
done
echo "[fix_app_dirs] created $created data dirs, $profile_dirs profile dirs"

# Realign ownership of pre-existing data dirs with the uid PMS assigned.
# The staged /data tree was restored from a backup, so some app dirs are still
# owned by system:system with 0777 perms. ART then refuses to load any dex from
# them ("Writable dex file ... is not allowed"), and GMS/SQLite cannot chmod its
# own files ("FileUtils.setPermissions" warnings) and the app dies. Only dirs
# whose top-level owner is wrong are touched, so later boots stay cheap.
realigned=0
if [ -f /data/system/packages.list ]; then
    while read -r pkg auid rest; do
        case "$auid" in ''|*[!0-9]*) continue ;; esac
        for base in /data/user/0 /data/user_de/0; do
            d="$base/$pkg"
            [ -d "$d" ] || continue
            cur=$(stat -c %u "$d" 2>/dev/null)
            [ "$cur" = "$auid" ] && continue
            chown -R "$auid:$auid" "$d" 2>/dev/null
            chmod -R go-w "$d" 2>/dev/null
            realigned=$((realigned + 1))
        done
    done < /data/system/packages.list
fi
echo "[fix_app_dirs] realigned $realigned data dirs to their app uid"

# Gesture navigation. The UI activator writes navigation_mode too, but it can
# run before the settings provider is ready, which leaves the value at 0 and
# the navbar back to 3-button. Do it again here, after boot completed.
cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null
settings put secure navigation_mode 2 2>/dev/null

# Keep Messaging as the default SMS app. Without a holder of
# android.app.role.SMS the framework's InboundSmsHandler drops every incoming
# text before it reaches the provider, so a delivered code would vanish.
if [ "$(settings get secure sms_default_application)" != "com.android.messaging" ]; then
    cmd role add-role-holder --user 0 android.app.role.SMS com.android.messaging 2>/dev/null
    settings put secure sms_default_application com.android.messaging 2>/dev/null
    echo "[fix_app_dirs] restored default SMS app"
fi

# Bluetooth's GD stack asserts out of `storage_module.cc SaveImmediately` when
# it cannot persist its own config, and com.android.bluetooth then restarts
# every ~4 seconds for the rest of the session (1880 tombstones in one boot).
# The staged tree had no /data/misc/bluedroid at all; create it with the
# bluetooth uid (1002) so the stack can save bt_config.conf.
if [ ! -d /data/misc/bluedroid ]; then
    mkdir -p /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chown 1002:1002 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    chmod 0770 /data/misc/bluedroid /data/misc/bluetooth 2>/dev/null
    echo "[fix_app_dirs] created /data/misc/bluedroid for the bluetooth stack"
fi

# Code files must not be writable by the app that loads them. ART rejects any
# dex/apk/jar the calling uid could modify ("Writable dex file ... is not
# allowed"), which crash-looped GMS: its Dynamite modules in
# /data/user_de/0/.../app_chimera were installed 0755. The ownership pass above
# only touches dirs whose *top-level* owner is wrong, so GMS was skipped even
# though its files were wrong. Do this on both storages, cheaply.
code_files=0
for root in /data/user/0 /data/user_de/0; do
    [ -d "$root" ] || continue
    for f in $(find "$root" -type f \( -name '*.apk' -o -name '*.jar' -o -name '*.dex' \) -perm -0200 2>/dev/null); do
        chmod a-w "$f" 2>/dev/null && code_files=$((code_files + 1))
    done
done
echo "[fix_app_dirs] made $code_files code files read-only"

# The guest's Settings.Global.ADB_ENABLED defaults to null (treated as 0), and
# the guest's UsbDeviceManager drops the adb function from the USB gadget as
# soon as it starts. That is what kills the host adbd we rely on: adb dies
# seconds after Lineage boots and macOS stops seeing the phone at all. Turn it
# on so the gadget keeps adb, and read back what actually happened.
adb_before=$(getprop sys.usb.state)
settings put global adb_enabled 1 2>/dev/null
sleep 2
echo "[fix_app_dirs] adb_enabled=1 (usb.state was '$adb_before', now '$(getprop sys.usb.state)')"

# Record system services that failed to start (e.g. AdbService: "Failure
# starting ..."), so a problem behind a later crash can be traced without
# guessing from a fresh boot.
# SystemServer reports a service that threw during startup as
# "BOOT FAILURE starting X" (reportWtf) or "Failure starting X": catch both,
# plus anything mentioning AdbService, since that is the one we care about.
{
    logcat -d -b system 2>/dev/null | grep -a -E "BOOT FAILURE|Failure starting" | head -40
    echo "--- AdbService mentions ---"
    logcat -d -b system 2>/dev/null | grep -a -i "AdbService" | tail -10
} > /data/boot_failures.log 2>/dev/null || true
FIXAPPDIRS
chmod 755 "$STAGE/data/local/tmp/fix_app_dirs.sh" 2>/dev/null || true

# The guest has no installd, so nothing creates an app's data directories when
# it is installed. PMS records the package, then zygote aborts the first launch
# with "Failed to mount /data_mirror/data_de/null/0/<pkg> to
# /data/user_de/0/<pkg>: No such file or directory". Every app installed from
# inside Lineage -- Play Store, Aurora, adb -- used to crash on launch this way.
# Create the scaffolding installd would; /data_mirror is a bind of these trees.
cat > "$STAGE/data/local/tmp/ensure_app_storage.sh" <<'ENSUREAPP'
#!/system/bin/sh
created=0
[ -f /data/system/packages.list ] || exit 0
realigned=0
while read -r pkg auid rest; do
    case "$auid" in ''|*[!0-9]*) continue ;; esac
    for d in "/data/user/0/$pkg:0771" "/data/user_de/0/$pkg:0700"; do
        p=${d%:*}; mode=${d##*:}
        if [ -d "$p" ]; then
            # Reinstalling a package can assign a NEW uid while the old data
            # dirs survive (uninstall has no installd to delete them), and the
            # app then fails with "SQLiteCantOpenDatabaseException: unable to
            # open database file" because it cannot write its own directory.
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:$auid" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:$auid" "$p" 2>/dev/null
        chmod "$mode" "$p" 2>/dev/null
        created=$((created + 1))
    done
    # External storage: owner is the app, group is ext_data_rw (1078).
    for kind in data media obb; do
        p="/data/media/0/Android/$kind/$pkg"
        if [ -d "$p" ]; then
            cur=$(stat -c %u "$p" 2>/dev/null)
            if [ -n "$cur" ] && [ "$cur" != "$auid" ]; then
                chown -R "$auid:1078" "$p" 2>/dev/null && realigned=$((realigned + 1))
            fi
            continue
        fi
        mkdir -p "$p" 2>/dev/null || continue
        chown "$auid:1078" "$p" 2>/dev/null
        chmod 0770 "$p" 2>/dev/null
        created=$((created + 1))
    done
done < /data/system/packages.list

# Shared storage skeleton. Without it MediaProvider cannot create
# /storage/emulated/0/Pictures/Screenshots and taking a screenshot crashes
# SystemUI ("Failed to create directory: .../.pending-NNN"), and every save
# dialog has nowhere to put its file.
for d in Pictures Pictures/Screenshots DCIM DCIM/Camera Movies Music Documents \
         Alarms Notifications Podcasts Ringtones Download; do
    p="/data/media/0/$d"
    [ -d "$p" ] && continue
    mkdir -p "$p" 2>/dev/null || continue
    chown 1023:1023 "$p" 2>/dev/null
    chmod 0775 "$p" 2>/dev/null
    created=$((created + 1))
done

if [ "$created" -gt 0 ] || [ "$realigned" -gt 0 ]; then
    echo "[ensure_app_storage] created $created dirs, realigned $realigned to new uids"
fi
exit 0
ENSUREAPP
chmod 755 "$STAGE/data/local/tmp/ensure_app_storage.sh" 2>/dev/null || true

# A new install only becomes launchable once the dirs above exist, so sweep
# while Lineage is running instead of at boot only. Started by master_inner.
cat > "$STAGE/data/local/tmp/net_fix.sh" <<'NETFIX'
#!/system/bin/sh
# The guest's ConnectivityService cannot install its routes into the host's
# netd: every addRoute fails with "No such file or directory", so the final
# catch-all ip rule keeps pointing at a table from a previous network and all
# traffic ends in the "unreachable" rule. Symptom: the modem reports
# MOBILE[LTE] CONNECTED / VALIDATED, yet every app (Aurora, Play Store) says
# "check your internet connection" and even ping to the gateway fails.
# Keep a private table (4242) in sync with the live interface - wifi first,
# else mobile/CLAT - and point a catch-all rule at it. Idempotent.
have_v4() { ip -4 addr show "$1" 2>/dev/null | grep -q "inet "; }
iface=""
# Check wifi first (wlan0 on most devices, wlan1 on some).
for _w in wlan0 wlan1; do
    if have_v4 "$_w"; then iface=$_w; break; fi
done
if [ -z "$iface" ]; then
    # Mobile data: try Qualcomm rmnet_data*, Snapdragon IPA rmnet_ipa*, and
    # MediaTek ccmni* interfaces. Some Exynos builds use rmnet0/rmnet1.
    for d in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' \
               | grep -E '^(rmnet_data|rmnet_ipa|ccmni|rmnet)[0-9]'); do
        if have_v4 "$d"; then iface=$d; break; fi
    done
fi
[ -z "$iface" ] && exit 0
# --- DNS self-heal (rewritten, untested on device) ---------------------------
# Evidence: right after boot and after every Wi-Fi network re-creation
# (netId 100 -> 104 ...) the guest's NetworkMonitor reports
# PROBE_DNS ... ENONET, apps get "Unable to resolve host", and it recovers by
# itself after ~30 s. ENONET from the resolver means the netId has no DNS
# configuration yet: the guest's ConnectivityService (Android 16) configures
# the host's netd/DnsResolver (Android 17) late or not at all.
# The old heal toggled Wi-Fi off/on (at most every 90 s). Every toggle creates
# a NEW network id with the same unconfigured-resolver gap, so validation (and
# the setup wizard's "checking connection" spinner) could restart forever.
# It also tested DNS with `ping <hostname>`, which fails on networks that drop
# ICMP even when DNS works.
# Now: tell resolution failures apart from missing ICMP replies; when names
# fail but IP works, configure DNS for the CURRENT default netId directly
# (ndc resolver setnetdns + flushnet, and re-assert the default network),
# using the network's own DNS servers from `dumpsys connectivity`, else the
# gateway, else 1.1.1.1/8.8.8.8. Wi-Fi is only bounced if explicitly enabled,
# with exponential backoff and at most 4 times per session.
# Toggles (in $STAGE, mirrored into the guest's lineage_flags):
#   echo 0 > dns_heal                     (no DNS repair at all)
#   echo 1.1.1.1,9.9.9.9 > dns_servers    (force these resolvers)
#   echo 1 > net_bounce                   (allow the old Wi-Fi toggle as a last resort)
FLAGS=${LINEAGE_FLAGS:-/data/local/tmp/lineage_flags}
NSTATE=${NET_STATE_DIR:-/data}
gflag() {
    _v=$(cat "$FLAGS/$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}
# 0 = a name resolved (whether or not the host answers ICMP), 1 = it did not.
dns_ok() {
    _out=$(ping -c1 -W2 connectivitycheck.gstatic.com 2>&1); _rc=$?
    [ "$_rc" -eq 0 ] && return 0
    case "$_out" in
        *"unknown host"*|*"bad address"*|*"resolve"*|*"Name or service"*|*"No address"*|*"Temporary failure"*) return 1 ;;
    esac
    # iputils ping: 1 = resolved but no reply, 2 = any other error
    [ "$_rc" -eq 1 ] && return 0
    return 1
}
ip_ok() { ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; }
case "$(gflag dns_heal on)" in
    0|off|false|no|disable|disabled) ;;
    *)
    if ip_ok && ! dns_ok; then
        now=$(date +%s)
        last=$(cat "$NSTATE/net_dns_fix.ts" 2>/dev/null)
        if [ -z "$last" ] || [ $((now - last)) -ge 20 ]; then
            echo "$now" > "$NSTATE/net_dns_fix.ts"
            dump=$(dumpsys connectivity 2>/dev/null)
            netid=$(echo "$dump" | sed -n 's/.*Active default network: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
            if [ -n "$netid" ]; then
                servers=$(gflag dns_servers "" | tr ',' ' ')
                if [ -z "$servers" ]; then
                    servers=$(echo "$dump" | grep -m 1 "network{$netid}" \
                        | sed -n 's/.*DnsAddresses: *\[\([^]]*\)\].*/\1/p' | tr ', ' '\n\n' \
                        | sed 's#^/##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 2 | tr '\n' ' ')
                fi
                [ -n "$servers" ] || servers="1.1.1.1 8.8.8.8"
                ndc network default set "$netid" >/dev/null 2>&1
                # shellcheck disable=SC2086
                r=$(ndc resolver setnetdns "$netid" "" $servers 2>&1 | tr '\n' ' ')
                ndc resolver flushnet "$netid" >/dev/null 2>&1
                if dns_ok; then res="names resolve again"; else res="still failing"; fi
                echo "dns heal: netId $netid on $iface -> dns $servers (ndc: ${r:-ok}); $res"
            else
                echo "dns heal: names fail with IP up on $iface, but no default network in dumpsys"
            fi
            case "$(gflag net_bounce 0)" in
                1|on|true|yes)
                    if ! dns_ok; then
                        tries=$(cat "$NSTATE/net_bounce.count" 2>/dev/null | tr -dc '0-9'); tries=${tries:-0}
                        lastb=$(cat "$NSTATE/net_bounce.ts" 2>/dev/null | tr -dc '0-9'); lastb=${lastb:-0}
                        wait_s=$((90 << tries))
                        if [ "$tries" -lt 4 ] && [ $((now - lastb)) -ge "$wait_s" ]; then
                            case "$iface" in
                                wlan*)
                                    echo $((tries + 1)) > "$NSTATE/net_bounce.count"
                                    echo "$now" > "$NSTATE/net_bounce.ts"
                                    svc wifi disable >/dev/null 2>&1; sleep 2; svc wifi enable >/dev/null 2>&1
                                    echo "dns heal: wifi bounced (attempt $((tries + 1))/4, net_bounce=1)" ;;
                            esac
                        fi
                    fi ;;
            esac
        fi
    fi ;;
esac
subnet=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$2=="dev" && $3==d && $0 ~ /scope link/ && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\// {print $1; exit}')
[ -z "$subnet" ] && exit 0
gw=$(ip route show table all 2>/dev/null | awk -v d="$iface" \
    '$1=="default" && $2=="via" && $4=="dev" && $5==d && $3 ~ /^[0-9]+\./ {print $3; exit}')
# no IPv4 default anywhere (netd never installed one): assume the first host
[ -z "$gw" ] && gw="${subnet%.*}.1"
ip route replace "$subnet" dev "$iface" table 4242 2>/dev/null
ip route replace default via "$gw" dev "$iface" table 4242 2>/dev/null
# Priority must beat the per-uid rules netd already installed for previous
# networks (15040/29040/29998): app sockets carry an fwmark, so a catch-all
# placed after those still sends them into a dead table even though root's
# unmarked pings work.
cur=$(ip rule show 2>/dev/null | awk '/^14999:/{print $NF; exit}')
if [ "$cur" != "4242" ]; then
    ip rule del priority 14999 2>/dev/null
    ip rule add from all lookup 4242 priority 14999 2>/dev/null
    ip rule del priority 31999 2>/dev/null
    echo "net route repaired: $iface $subnet gw $gw"
fi
exit 0
NETFIX
chmod 755 "$STAGE/data/local/tmp/net_fix.sh" 2>/dev/null || true
# Optional Wi-Fi bounce budget (net_bounce=1) is per session.
rm -f "$STAGE/data/net_bounce.count" "$STAGE/data/net_bounce.ts" 2>/dev/null || true

cat > "$STAGE/data/local/tmp/app_storage_loop.sh" <<'APPLOOP'
#!/system/bin/sh
# Watches for installs/removals, gives the new package its data dirs, and makes
# the launcher re-query so the app actually shows up.
#
# Heat fix (untested on device): ensure_app_storage.sh used to run every 10 s.
# For every package (~300 with the owner's ~200 apps) it spawns `stat` for up
# to 5 directories, i.e. ~1500 fork+exec every 10 s, all session long, roughly
# 15-30 % of a core for nothing. Everything it fixes is caused by an install,
# removal or reinstall, and all of those change packages.list. So: run it when
# packages.list changes, plus a full sweep every storage_sweep_full loops
# (default 30 = 5 min) as a safety net.
# Toggle: echo 1 > $STAGE/storage_sweep_full   (sweep every 10 s, old behaviour)
FLAGS=${LINEAGE_FLAGS:-/data/local/tmp/lineage_flags}
STORAGE_SCRIPT=${ENSURE_APP_STORAGE:-/data/local/tmp/ensure_app_storage.sh}
NET_SCRIPT=${NET_FIX:-/data/local/tmp/net_fix.sh}
PKG_LIST=${PACKAGES_LIST:-/data/system/packages.list}
APP_LOG=${APP_STORAGE_LOG:-/data/app_storage.log}
LOOP_SLEEP=${APP_LOOP_SLEEP:-10}
LOOP_MAX=${APP_LOOP_MAX:-0}
full=$(cat "$FLAGS/storage_sweep_full" 2>/dev/null | tr -dc '0-9')
[ -n "$full" ] && [ "$full" -gt 0 ] || full=30
last=""
n=0
while true; do
    sleep "$LOOP_SLEEP"
    case "$(getprop sys.boot_completed)" in 1) ;; *) continue ;; esac
    n=$((n + 1))
    netout=$(/system/bin/sh "$NET_SCRIPT" 2>/dev/null)
    [ -n "$netout" ] && echo "$(date) $netout" >> "$APP_LOG"
    cur=$(md5sum "$PKG_LIST" 2>/dev/null | cut -d' ' -f1)
    out=""
    if [ "$cur" != "$last" ] || [ $((n % full)) -eq 0 ]; then
        out=$(/system/bin/sh "$STORAGE_SCRIPT" 2>/dev/null)
    fi
    if [ -n "$last" ] && { [ "$cur" != "$last" ] || [ -n "$out" ]; }; then
        # A package appeared or went away. LauncherApps caches the app list, so
        # something installed from Aurora or Play Store is missing from both the
        # drawer and app search until the launcher re-queries. Restarting the
        # launcher forces that and does not touch whatever app is in front.
        am force-stop com.android.launcher3 2>/dev/null
        echo "$(date) package list changed -> launcher refreshed ${out:+($out)}" >> "$APP_LOG"
    elif [ -n "$out" ]; then
        echo "$(date) $out" >> "$APP_LOG"
    fi
    last=$cur
    [ "$LOOP_MAX" -gt 0 ] && [ "$n" -ge "$LOOP_MAX" ] && exit 0
done
APPLOOP
chmod 755 "$STAGE/data/local/tmp/app_storage_loop.sh" 2>/dev/null || true

echo "=== 6. Setting up /system/xbin/su (KernelSU Bridge) ==="
if ! mount | grep -q "$ROOTFS/system/xbin "; then
    $BB mount -t tmpfs tmpfs "$ROOTFS/system/xbin"
    SU_SRC="/data/adb/ksud"
    [ -f "$SU_SRC" ] || SU_SRC=$(which su 2>/dev/null)
    [ -f "$SU_SRC" ] || SU_SRC=$(find /data/adb /system/bin -name su 2>/dev/null | head -n 1)
    [ -f "$SU_SRC" ] && cp "$SU_SRC" "$ROOTFS/system/xbin/su" && chmod 755 "$ROOTFS/system/xbin/su"
fi

echo "=== 7. Setting up Fresh APEX tmpfs ==="
# Clean any stale submounts and ensure a clean, writable tmpfs
for m in $(cat /proc/mounts 2>/dev/null | grep "$ROOTFS/apex" | awk '{print $2}' | sort -r); do
    $BB umount -l "$m" 2>/dev/null || true
done
$BB umount -l "$ROOTFS/apex" 2>/dev/null || true
$BB mount -t tmpfs tmpfs "$ROOTFS/apex"

# NOTE: the list is only a hint; apexd (host daemon) owns the preinstalled set
# and PMS parses the paths it reports. That is why the host's apex directories
# are bound into this rootfs (see the /system_ext/apex and /system/apex binds):
# every path in this list must resolve after the pivot.
if [ -f "$STAGE/clean_apex_info_list.xml" ]; then
    cp "$STAGE/clean_apex_info_list.xml" "$ROOTFS/apex/apex-info-list.xml"
else
    cp -a /apex/apex-info-list.xml "$ROOTFS/apex/" 2>/dev/null || true
fi
chmod 644 "$ROOTFS/apex/apex-info-list.xml" 2>/dev/null || true

echo "=== 8. Direct Mounting Extracted APEX Payloads ==="
# Android 17+ images: APEXes taken from One UI instead of the image (step 9
# binds the host's copy). Tethering must match the BPF programs One UI's
# bpfloader pinned in /sys/fs/bpf: on an S26 Ultra the Play-updated host module
# pins map_netd_uid_permission_chunk_map, and LineageOS 24's own module aborts
# system_server with "Cannot open uid permission map". Space-separated short
# names; "none" uses the image own for everything. cellbroadcast: its
# CellBroadcastService shares android.uid.networkstack with Tethering, so it
# must be signed like it ("Signature mismatch on system package
# com.android.cellbroadcastservice", verified on an S26 Ultra).
# Change: echo "tethering wifi" > $STAGE/host_apex
HOST_APEX=""
if [ "$LEGACY16" = 0 ]; then
    HOST_APEX=$(cat "$STAGE/host_apex" 2>/dev/null | tr -d '\r')
    [ -z "$HOST_APEX" ] && HOST_APEX="tethering cellbroadcast"
    [ "$HOST_APEX" = none ] && HOST_APEX=""
    echo "APEXes taken from One UI: ${HOST_APEX:-none}"
fi

mount_payload() {
    NAME="$1"
    TARGET="$2"
    IMG="$STAGE/${NAME}_payload.img"
    DEST="$ROOTFS/apex/$TARGET"
    for h in $HOST_APEX; do
        [ "$h" = "$NAME" ] && { echo "$NAME: using One UI's APEX"; return 0; }
    done
    if [ ! -f "$IMG" ]; then
        CAPEX="$ROOTFS/system/apex/com.android.${NAME}.capex"
        [ -f "$CAPEX" ] || CAPEX="$ROOTFS/system/system_ext/apex/com.android.${NAME}.capex"
        APEX="$ROOTFS/system/apex/com.android.${NAME}.apex"
        [ -f "$APEX" ] || APEX="$ROOTFS/system/system_ext/apex/com.android.${NAME}.apex"
        if [ -f "$CAPEX" ]; then
            $BB unzip -p "$CAPEX" original_apex > "$STAGE/temp_${NAME}.apex" 2>/dev/null
            $BB unzip -p "$STAGE/temp_${NAME}.apex" apex_payload.img > "$IMG" 2>/dev/null
            rm -f "$STAGE/temp_${NAME}.apex"
        elif [ -f "$APEX" ]; then
            $BB unzip -p "$APEX" apex_payload.img > "$IMG" 2>/dev/null
        fi
    fi
    [ -f "$IMG" ] || return 0
    if mount | grep "$DEST " | grep -q "/dev/block/dm-"; then
        $BB umount -l "$DEST" 2>/dev/null || true
        for vdir in "$ROOTFS/apex/${TARGET}"@*; do
       [ -d "$vdir" ] && $BB umount -l "$vdir" 2>/dev/null || true
        done
    fi
    if mount | grep "$DEST " | grep -q "/dev/block/loop"; then
        echo "$NAME already mounted on loop at $DEST"
        return 0
    fi
    mkdir -p "$DEST"
    $BB umount -l "$DEST" 2>/dev/null || true
    LOOP=$($BB losetup -f)
    $BB losetup "$LOOP" "$IMG"
    PFS=$(img_fstype "$IMG")
    $BB mount -t "$PFS" -o ro "$LOOP" "$DEST"
    echo "Direct mounted $NAME on $LOOP -> $DEST"
    for vdir in "$ROOTFS/apex/${TARGET}"@*; do
        if [ -d "$vdir" ]; then
            $BB umount -l "$vdir" 2>/dev/null || true
            $BB mount -t "$PFS" -o ro "$LOOP" "$vdir"
            echo "Direct mounted $NAME on $LOOP -> $vdir"
        fi
    done
    # Also discover and mount any versioned APEXes existing in host /apex
    for hdir in /apex/${TARGET}@*; do
        if [ -d "$hdir" ]; then
            vbase=$(basename "$hdir")
            vdest="$ROOTFS/apex/$vbase"
            mkdir -p "$vdest"
            $BB umount -l "$vdest" 2>/dev/null || true
            $BB mount -t "$PFS" -o ro "$LOOP" "$vdest"
            echo "Direct mounted $NAME on $LOOP -> $vdest (from host $vbase)"
        fi
    done
}

mount_payload "art" "com.android.art"
mount_payload "i18n" "com.android.i18n"
mount_payload "runtime" "com.android.runtime"
mount_payload "sdkext" "com.android.sdkext"
mount_payload "nfcservices" "com.android.nfcservices"
mount_payload "tethering" "com.android.tethering"
mount_payload "crashrecovery" "com.android.crashrecovery"
mount_payload "cellbroadcast" "com.android.cellbroadcast"
mount_payload "extservices" "com.android.extservices"
mount_payload "permission" "com.android.permission"
mount_payload "wifi" "com.android.wifi"
mount_payload "appsearch" "com.android.appsearch"
mount_payload "mediaprovider" "com.android.mediaprovider"
mount_payload "adservices" "com.android.adservices"
mount_payload "rkpd" "com.android.rkpd"
mount_payload "healthfitness" "com.android.healthfitness"
mount_payload "ondevicepersonalization" "com.android.ondevicepersonalization"
mount_payload "configinfrastructure" "com.android.configinfrastructure"
mount_payload "bt" "com.android.bt"
mount_payload "conscrypt" "com.android.conscrypt"
mount_payload "media" "com.android.media"
mount_payload "media.swcodec" "com.android.media.swcodec"
mount_payload "ipsec" "com.android.ipsec"
mount_payload "devicelock" "com.android.devicelock"
mount_payload "os.statsd" "com.android.os.statsd"
mount_payload "profiling" "com.android.profiling"
mount_payload "scheduling" "com.android.scheduling"
mount_payload "telephonycore" "com.android.telephonycore"
mount_payload "tzdata" "com.android.tzdata"
mount_payload "uwb" "com.android.uwb"
mount_payload "virt" "com.android.virt"
mount_payload "neuralnetworks" "com.android.neuralnetworks"
mount_payload "resolv" "com.android.resolv"
mount_payload "uprobestats" "com.android.uprobestats"
mount_payload "adbd" "com.android.adbd"
mount_payload "compos" "com.android.compos"
mount_payload "apex.cts.shim" "com.android.apex.cts.shim"
# Android 17 (LineageOS 24) only; skipped when the image has no such APEX.
mount_payload "npumanager" "com.android.npumanager"
mount_payload "webapp" "com.android.webapp"

# Payload extractions above used the GSI's own /system/apex and /system/system_ext/apex
# files. Now that the images are cached, present the HOST's /system/apex and
# /system_ext/apex to the container so the preinstalled paths reported by host
# apexd all resolve.
if [ -d /system/apex ]; then
    mkdir -p "$ROOTFS/system/apex"
    mount | grep -q "$ROOTFS/system/apex " || $BB mount --bind /system/apex "$ROOTFS/system/apex"
fi
if [ -d /system_ext/apex ]; then
    mkdir -p "$ROOTFS/system/system_ext/apex"
    mount | grep -q "$ROOTFS/system/system_ext/apex " || $BB mount --bind /system_ext/apex "$ROOTFS/system/system_ext/apex"
fi

if [ "$LEGACY16" = 0 ]; then
    for a in "$ROOTFS"/apex/com.android.art "$ROOTFS"/apex/com.android.art@*; do
        [ -f "$a/javalib/service-art.jar" ] || continue
        $BB umount -l "$a/javalib/service-art.jar" 2>/dev/null
        $BB mount --bind "$STAGE/service-art17_patched.jar" "$a/javalib/service-art.jar" && echo "Bound service-art17_patched.jar -> $a"
    done
fi

echo "=== 9. Bind-mounting Remaining Non-Payload APEXes ==="
for a in /apex/*; do
    [ -d "$a" ] || continue
    base=$(basename "$a")
    # Android 17 system_server starts LifeGuardManagerService from
    # /apex/com.samsung.android.lifeguard/javalib/service-lifeguard.jar on
    # this phone (verified on an S26 Ultra with LineageOS 24: "Creating a
    # ClassLoader from .../service-lifeguard.jar is not allowed" when the APEX
    # is missing). Bind it; derive_classpath then adds its jars.
    case "$LEGACY16:$base" in
        0:com.samsung.android.lifeguard|0:com.samsung.android.lifeguard@*)
            if ! mount | grep -q "$ROOTFS/apex/$base "; then
                mkdir -p "$ROOTFS/apex/$base"
                $BB mount --bind "$a" "$ROOTFS/apex/$base" && echo "Bound $base (Android 17 LifeGuard)"
            fi
            continue
            ;;
    esac
    case "$base" in
        *samsung*)
            continue
            ;;
    esac
    # Skip if already mounted (all 37 GSI com.android.* APEXes and their @version
    # dirs are already mounted above in Step 8)
    if ! mount | grep -q "$ROOTFS/apex/$base "; then
        mkdir -p "$ROOTFS/apex/$base"
        $BB mount --bind "$a" "$ROOTFS/apex/$base" 2>/dev/null || true
        echo "Bound $base -> $ROOTFS/apex/$base"
    fi
done

# aconfig flag storage for Android 17+ images. Their framework reads feature
# flags from /metadata/aconfig/{maps,boot}/<container>.*, but the image's own
# /metadata is an empty directory. Verified on an S26 Ultra with LineageOS 24:
# system_server dies at boot in AdvancedProtectionService with
#   IllegalArgumentException: Invalid feature flag:
#   android.security.aapm_feature_disable_insecure_wifi_autojoin
# Build a private copy on a tmpfs: One UI's files for the containers the guest
# shares with the host (vendor, odm), then the guest's own flag files for its
# system, product, system_ext and every mounted APEX. Persistent flag overrides
# (/metadata/aconfig/flags) start empty. One UI's /metadata is untouched.
# Off: echo 0 > $STAGE/guest_aconfig
GAC=$(cat "$STAGE/guest_aconfig" 2>/dev/null | tr -d ' \t\r\n')
case "$GAC" in ""|auto) [ "$LEGACY16" = 0 ] && GAC=1 ;; esac
case "$GAC" in
    1|on|true|yes)
        echo "=== 9b. Guest aconfig flag storage ==="
        GM="$ROOTFS/metadata"
        $BB umount -l "$GM" 2>/dev/null || true
        if $BB mount -t tmpfs -o mode=0755 tmpfs "$GM"; then
            mkdir -p "$GM/aconfig/maps" "$GM/aconfig/boot" "$GM/aconfig/flags"
            cp -a /metadata/aconfig/maps/. "$GM/aconfig/maps/" 2>/dev/null
            cp -a /metadata/aconfig/boot/. "$GM/aconfig/boot/" 2>/dev/null
            add_container() {
                [ -f "$2/package.map" ] && [ -f "$2/flag.map" ] && [ -f "$2/flag.val" ] || return 0
                cp -f "$2/package.map" "$GM/aconfig/maps/$1.package.map"
                cp -f "$2/flag.map" "$GM/aconfig/maps/$1.flag.map"
                cp -f "$2/flag.val" "$GM/aconfig/boot/$1.val"
                [ -f "$2/flag.info" ] && cp -f "$2/flag.info" "$GM/aconfig/boot/$1.info"
                GAC_N=$((GAC_N + 1))
            }
            GAC_N=0
            add_container system "$ROOTFS/system/etc/aconfig"
            add_container product "$ROOTFS/system/product/etc/aconfig"
            add_container system_ext "$ROOTFS/system/system_ext/etc/aconfig"
            for a in "$ROOTFS"/apex/com.android.*; do
                case "$a" in *@*) continue ;; esac
                add_container "$(basename "$a")" "$a/etc"
            done
            chown -R 1000:1000 "$GM/aconfig" 2>/dev/null
            chown 0:1000 "$GM/aconfig" "$GM/aconfig/maps" "$GM/aconfig/boot" "$GM/aconfig/flags" 2>/dev/null
            chmod 775 "$GM/aconfig" "$GM/aconfig/maps" "$GM/aconfig/boot"
            chmod 770 "$GM/aconfig/flags"
            chmod 644 "$GM"/aconfig/maps/* "$GM"/aconfig/boot/* 2>/dev/null
            echo "Guest aconfig storage: $GAC_N guest containers"
        else
            echo "Guest aconfig storage: tmpfs mount failed"
        fi
        ;;
esac

# PermissionController patch, second pass. The same block near step 4 runs
# before the apex set is mounted, so find(1) finds nothing and Samsung's
# PermissionController stays behind. Samsung's build requires
# android.permission.RANGING, which the GSI platform does not define, so every
# runtime-permission dialog dies with
#   IllegalStateException: android.permission.RANGING not defined by platform
#   -> "Permission controller keeps stopping"
# and Gallery/Phone/Calendar can never be granted anything. Bind it now that
# /apex/com.android.permission actually exists.
if [ "$LEGACY16" = 1 ] && [ -f "$STAGE/PermissionController_patched.apk" ]; then
    chmod 644 "$STAGE/PermissionController_patched.apk" 2>/dev/null || true
    for PERM_APK in $(find "$ROOTFS/apex/com.android.permission" -name "PermissionController.apk" 2>/dev/null); do
        $BB umount -l "$PERM_APK" 2>/dev/null || true
        $BB mount --bind "$STAGE/PermissionController_patched.apk" "$PERM_APK" 2>/dev/null && echo "Bound PermissionController_patched.apk (late) -> $PERM_APK"
    done
else
    [ "$LEGACY16" = 1 ] && echo "!!! WARNING: PermissionController_patched.apk missing from $STAGE"
    [ "$LEGACY16" = 1 ] && echo "!!! Samsung's PermissionController will crash every runtime-permission dialog"
    [ "$LEGACY16" = 1 ] && echo "!!! (android.permission.RANGING not defined by platform)"
fi

# One UI's Tethering module (see HOST_APEX) is Google-signed and shares the
# android.uid.networkstack user with the NetworkStack app, so the image's
# test-key NetworkStack makes PackageManager abort system_server ("Signature
# mismatch on system package com.google.android.networkstack.tethering for
# shared user android.uid.networkstack", verified on an S26 Ultra). Use One
# UI's Google-signed NetworkStack and its privapp allowlist with it.
case " $HOST_APEX " in
    *" tethering "*)
        if [ -d /system/priv-app/NetworkStackGoogle ] && [ -d "$ROOTFS/system/priv-app/NetworkStack" ]; then
            $BB mount --bind /system/priv-app/NetworkStackGoogle "$ROOTFS/system/priv-app/NetworkStack" && \
                echo "NetworkStack: using One UI's NetworkStackGoogle"
            if [ -f /system/etc/permissions/GoogleNetworkStack_permissions.xml ] && [ -f "$ROOTFS/system/etc/permissions/NetworkStack.xml" ]; then
                $BB mount --bind /system/etc/permissions/GoogleNetworkStack_permissions.xml "$ROOTFS/system/etc/permissions/NetworkStack.xml"
            fi
        fi
        ;;
esac

# Cut every mount under the rootfs off from its source. Binds of One UI's
# /apex/* (and /dev, /mnt, ...) are created as peers of the host mounts, so
# unmounting them later (return_to_oneui.sh) also unmounted One UI's own
# APEXes: apexd then failed and init rebooted the phone
# (ro.boot.bootreason "reboot,apexd-failed", seen on an S26 Ultra after
# every return from Lineage).
$BB mount --make-rprivate "$ROOTFS" 2>/dev/null && echo "Rootfs mounts made private"

echo "=== ALL MOUNTS PREPARED SUCCESSFULLY ==="
