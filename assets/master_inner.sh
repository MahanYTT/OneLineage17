#!/system/bin/sh
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

echo "[Pivoted Root] Preparing pivot..."
cd /data/local/tmp/lineage_stage/rootfs
$BB mount --make-rprivate /
if ! $BB pivot_root . postinstall; then
    echo "[Pivoted Root] Fallback: bind mounting rootfs onto itself..."
    $BB mount --bind . .
    if ! $BB pivot_root . postinstall; then
        echo "[Pivoted Root] FATAL: pivot_root failed completely! Aborting."
        exit 1
    fi
fi
$BB mount -t proc proc /proc

export PATH=/system/bin:/system/xbin

echo "[Pivoted Root] Setting up /data_mirror and /data/data mounts for Zygote isolation..."
$BB mount --bind /data/user/0 /data/data 2>/dev/null || true
$BB mount -t tmpfs tmpfs /data_mirror 2>/dev/null || true
mkdir -p /data_mirror/data_de/null/0 /data_mirror/data_ce/null/0 /data_mirror/cur_profiles /data_mirror/ref_profiles
chmod -R 777 /data_mirror
$BB mount --bind /data/user_de/0 /data_mirror/data_de/null/0 2>/dev/null || true
$BB mount --bind /data/user/0 /data_mirror/data_ce/null/0 2>/dev/null || true
mkdir -p /data/misc/profiles/cur /data/misc/profiles/ref
$BB mount --bind /data/misc/profiles/cur /data_mirror/cur_profiles 2>/dev/null || true
$BB mount --bind /data/misc/profiles/ref /data_mirror/ref_profiles 2>/dev/null || true

echo "[Pivoted Root] Setting up /data/media and emulated storage..."
mkdir -p /data/media/0/Android /data/media/0/Pictures/Screenshots /data/media/0/Download /data/media/0/DCIM /data/media/0/Documents
chown -R 1023:1023 /data/media 2>/dev/null || true
chmod -R 777 /data/media 2>/dev/null || true
$BB mount -t tmpfs tmpfs /storage 2>/dev/null || true
mkdir -p /storage/emulated/0
$BB mount --bind /data/media/0 /storage/emulated/0 2>/dev/null || true
mkdir -p /mnt/user/0
$BB mount -t tmpfs tmpfs /mnt/user/0 2>/dev/null || true
mkdir -p /mnt/user/0/emulated
$BB mount --bind /data/media/0 /mnt/user/0/emulated 2>/dev/null || true

echo "[Pivoted Root] Rootfs successfully activated as /"
echo "[Pivoted Root] Testing /dev/null resolution:"
exec 8< /dev/null
echo -n "FD 8: "
$BB readlink /proc/$$/fd/8
exec 8<&-

echo "[Pivoted Root] Testing su availability:"
su -c id || echo "su check non-fatal"

echo "[Pivoted Root] Starting LineageOS SurfaceFlinger..."
# sf.log used to grow without bound: the guest's RenderEngine dumps LLVM IR for
# every shader it compiles ("Global Value @fullLiteral...") and got to 300+ MB in
# ~3 minutes, filling /data. SurfaceFlinger's real diagnostics go through logcat,
# so stderr can be dropped.
/system/bin/surfaceflinger > /dev/null 2>&1 &
SF_PID=$!
echo "[Pivoted Root] SurfaceFlinger PID: $SF_PID"
sleep 2

echo "[Pivoted Root] Starting LineageOS BootAnimation..."
setprop service.bootanim.exit 0
/system/bin/bootanimation > /data/anim.log 2>&1 &
ANIM_PID=$!
echo "[Pivoted Root] BootAnimation PID: $ANIM_PID"
sleep 1

echo "[Pivoted Root] Starting LineageOS Vold..."
/system/bin/vold --blkid_context=u:r:blkid:s0 --blkid_untrusted_context=u:r:blkid_untrusted:s0 --fsck_context=u:r:fsck:s0 --fsck_untrusted_context=u:r:fsck_untrusted:s0 > /data/vold.log 2>&1 &
VOLD_PID=$!
echo "[Pivoted Root] Vold PID: $VOLD_PID"
sleep 1

# Wifi. switch_to_lineage.sh stops the host wificond; the guest's own registers
# IWificond before WifiService initialises, and drives Samsung's wifi HAL (which
# is still registered by host init) with matching AIDL.
echo "[Pivoted Root] Starting LineageOS wificond..."
/system/bin/wificond > /data/wificond.log 2>&1 &
WIFICOND_PID=$!
echo "[Pivoted Root] wificond PID: $WIFICOND_PID"
sleep 1

# Lineage's own mediaserver (see "mediaserver" in switch_to_lineage.sh): serves
# media.player and the codec list in Lineage's format, so SystemUI and
# system_server stop looping (and leaking) on One UI's.
case "$(cat /data/local/tmp/lineage_flags/guest_mediaserver 2>/dev/null | tr -d ' \t\r\n')" in
    0|off|false|no) echo "[Pivoted Root] guest mediaserver disabled (flag)" ;;
    *)
        # The GSI ships mediaserver64/mediaserver32, not a plain mediaserver
        # (verified: "/system/bin/mediaserver: not found" left media.player
        # missing, so ringtones, settings sounds and video all failed).
        MS=""
        for b in /system/bin/mediaserver64 /system/bin/mediaserver /system/bin/mediaserver32; do
            [ -x "$b" ] && { MS=$b; break; }
        done
        if [ -n "$MS" ]; then
            $MS > /data/mediaserver.log 2>&1 &
            echo "[Pivoted Root] $MS PID: $!"
        else
            echo "[Pivoted Root] WARNING: no mediaserver binary in the GSI"
        fi ;;
esac

# Lineage's own cameraserver (see "Camera" in switch_to_lineage.sh, which
# stopped One UI's and resolved the flag).
case "$(cat /data/local/tmp/lineage_flags/guest_cameraserver 2>/dev/null | tr -d ' \t\r\n')" in
    1)
        if [ -x /system/bin/cameraserver ]; then
            /system/bin/cameraserver > /data/cameraserver.log 2>&1 &
            echo "[Pivoted Root] cameraserver PID: $!"
        else
            echo "[Pivoted Root] WARNING: no cameraserver binary in the GSI"
        fi ;;
esac

# Overlay idmaps. idmap2 refuses the GSI's product overlays because framework-res
# does not declare the targeted resources as overlayable, so OMS ends up with no
# idmap at all and silently ignores every overlay: gesture navigation never
# applies (navbar stays 3-button) and the SystemUI accent overlays do nothing.
# Build the nav-bar idmap ourselves, before zygote can cache the empty overlay.
NAV_IDMAP="/data/resource-cache/system@product@overlay@NavigationBarModeGestural@NavigationBarModeGesturalOverlay.apk@idmap"
NAV_OV="/system/product/overlay/NavigationBarModeGestural/NavigationBarModeGesturalOverlay.apk"
mkdir -p /data/resource-cache
if [ ! -s "$NAV_IDMAP" ] && [ -f "$NAV_OV" ]; then
    echo "[Pivoted Root] Generating gesture-nav overlay idmap..."
    /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
        --overlay-apk-path "$NAV_OV" --idmap-path "$NAV_IDMAP" --ignore-overlayable \
        > /data/idmap.log 2>&1 \
        && chmod 644 "$NAV_IDMAP" && chown system:system "$NAV_IDMAP" \
        && echo "[Pivoted Root] idmap OK ($(wc -c < "$NAV_IDMAP") bytes)" \
        || echo "[Pivoted Root] idmap FAILED: $(head -n1 /data/idmap.log 2>/dev/null)"
fi

# Newly installed apps have no data directories (the guest has no installd), and
# zygote kills their first launch with "Failed to mount /data_mirror/...". This
# sweep creates them while Lineage runs, so Play Store/Aurora installs become
# launchable within ~15 s.
if [ -x /system/bin/setsid ]; then
    setsid /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
else
    /system/bin/sh /data/local/tmp/app_storage_loop.sh < /dev/null > /dev/null 2>&1 &
fi
echo "[Pivoted Root] App storage sweeper started..."

echo "[Pivoted Root] Cleaning stale sockets..."
rm -f /dev/socket/zygote /dev/socket/usap_pool_primary 2>/dev/null || true

# adbd stays One UI's (Android 17). Seen on an S26 Ultra: Lineage's
# AdbDebuggingManager connects to adbd's control socket right after boot and
# within about a minute every adb service hangs, even `adb reboot`, while
# usb.state never changes (so the gadget was not rebuilt). Hide the socket
# from Lineage only: adbd keeps checking known keys itself, the framework just
# gets "connection refused". This namespace is private (make-rprivate above),
# so One UI's /dev/socket/adbd is untouched.
# Result on device: adb over USB still stalled ~100 s after boot with the
# socket hidden, while adb over Wi-Fi kept working, so the stall is in the USB
# path, not here. Kept as an experiment, OFF by default.
# On: echo 1 > /data/local/tmp/lineage_stage/adb_framework_block
case "$(cat /data/local/tmp/lineage_flags/adb_framework_block 2>/dev/null | tr -d ' \t\r\n')" in
    ""|0|off|false|no) ;;
    *)
        if [ -S /dev/socket/adbd ] && $BB mount --bind /dev/null /dev/socket/adbd 2>/dev/null; then
            echo "[Pivoted Root] adbd control socket hidden from Lineage"
        else
            echo "[Pivoted Root] could not hide adbd control socket"
        fi ;;
esac

# Fake FRP partition (guest_fake_frp in master_prepare.sh): ueventd may have
# reset the loop node to root:root after it was bound; system_server opens it
# as uid system ("EACCES" otherwise).
FRP_NODE=$(readlink -f "$(getprop ro.frp.pst)" 2>/dev/null)
[ -b "$FRP_NODE" ] && chown 1000:1000 "$FRP_NODE" 2>/dev/null && chmod 600 "$FRP_NODE" 2>/dev/null

# Android 17+ images (e.g. LineageOS 24): zygote_exec has the Android 16
# class paths compiled in, which do not match a newer image. Ask the image
# itself (derive_classpath reads the classpath fragments of /system and every
# mounted APEX) and start zygote through zygote_exec17, which takes them from
# the environment. Android 16 images keep using zygote_exec unchanged.
GUEST_SDK=$(grep -m1 '^ro.build.version.sdk=' /system/build.prop 2>/dev/null | cut -d= -f2)
case "$GUEST_SDK" in ''|*[!0-9]*) GUEST_SDK=36 ;; esac
if [ "$GUEST_SDK" -ge 37 ] && [ -x /data/zygote_exec17 ]; then
    DCP=""
    for b in /apex/com.android.sdkext/bin/derive_classpath /system/bin/derive_classpath; do
        [ -x "$b" ] && { DCP=$b; break; }
    done
    mkdir -p /data/system/environ
    rm -f /data/system/environ/classpath
    if [ -n "$DCP" ] && $DCP /data/system/environ/classpath > /data/derive_classpath.log 2>&1             && [ -s /data/system/environ/classpath ]; then
        while read -r kw name value; do
            [ "$kw" = export ] && [ -n "$name" ] && export "$name=$value"
        done < /data/system/environ/classpath
        echo "[Pivoted Root] SDK $GUEST_SDK: class paths from $DCP, launching zygote_exec17..."
        exec /data/zygote_exec17
    fi
    echo "[Pivoted Root] SDK $GUEST_SDK: derive_classpath failed (see /data/derive_classpath.log), falling back to zygote_exec"
fi

echo "[Pivoted Root] Launching LineageOS Zygote & SystemServer via zygote_exec..."
exec /data/zygote_exec
