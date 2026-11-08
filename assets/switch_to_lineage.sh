#!/system/bin/sh
# OneLineage Userspace Takeover Orchestrator
STAGE="/data/local/tmp/lineage_stage"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
RP=$(which resetprop 2>/dev/null || echo "/data/adb/ksu/bin/resetprop")
[ -x "$RP" ] || RP=$(find /data/adb /system -name resetprop 2>/dev/null | head -n 1)

export BB
export RP
export STAGE

set_prop() {
    if [ -n "$RP" ] && [ -x "$RP" ]; then
        "$RP" "$1" "$2" 2>/dev/null || true
    else
        setprop "$1" "$2" 2>/dev/null || true
    fi
}

BACKUP_DIR="/data/local/tmp/lineage_backups"

# Toggle files. Every optional behaviour added for the overheating / setup /
# adb work reads a small file in $STAGE, the same way `density` works:
#   echo 0 > /data/local/tmp/lineage_stage/<name>   (switch it off)
#   rm /data/local/tmp/lineage_stage/<name>         (back to the default)
# /data/local/tmp/lineage_ctl.sh lists them all ("lineage_ctl.sh flags").
flag() {
    _v=$(cat "$STAGE/$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}
is_off() { case "$1" in 0|off|false|no|disable|disabled) return 0 ;; esac; return 1; }

# Host properties changed for the session are recorded here first and put back
# by return_to_oneui.sh, so One UI never inherits them. An existing file is
# kept (a session that never returned): it still holds the true originals.
SAVED_PROPS="$STAGE/saved_props"
save_set_prop() {
    grep -q "^$1=" "$SAVED_PROPS" 2>/dev/null || echo "$1=$(getprop "$1")" >> "$SAVED_PROPS"
    setprop "$1" "$2" 2>/dev/null || true
}

echo "=== LINEAGEOS 23.2 TAKEOVER STARTING ==="

# Put SELinux in permissive mode for the duration of the takeover. The guest
# userspace is a foreign, unlabelled-for-this-policy userspace: its
# system_server runs as u:r:system_server:s0 against Samsung's policy, and MAC
# denials there surface as confusing EACCES/ENOENT deep inside system_server
# (e.g. settings.db "doesn't exist", users/0.xml EACCES). master_prepare.sh
# relabels the staged /data properly, but permissive is the safety net that
# keeps the rest of the guest boot from tripping over labels we cannot predict.
# return_to_oneui.sh restores enforcing.
setenforce 0 2>/dev/null || true
echo "SELinux mode: $(getenforce 2>/dev/null || echo unknown)"

# --- IMS / SMS REGISTRATION GATE -----------------------------------------
# The guest has no ImsService of its own, so the modem's IMS registration is
# owned by One UI's imsd and survives the takeover. That registration is what
# makes SMS behave: with it, T-Mobile delivers inbound SMS promptly (Samsung's
# RIL hands SMSoIP messages to the framework as normal SMS) and the modem
# accepts mobile-originated SMS. Without it, voice sits OUT_OF_SERVICE, sends
# fail with RESULT_ERROR_NO_SERVICE and inbound codes fall back to the SMSC
# retry schedule, arriving 20-40 minutes late - and every radio nudge then
# appears to "magically" deliver them.
# So: make sure imsd is up, and give the modem a moment to (re)register before
# the pivot. Never stop imsd afterwards; killing it was what degraded SMS.
if ! pidof imsd >/dev/null 2>&1; then
    setprop ctl.start imsd 2>/dev/null || true
fi
ims_i=0
ims_st=1
while [ "$ims_i" -lt 45 ]; do
    if dumpsys telephony.registry 2>/dev/null | grep -q 'mVoiceRegState=0'; then
        ims_st=0
        break
    fi
    ims_i=$((ims_i + 1))
    sleep 2
done
echo "IMS gate: voiceRegState=$ims_st after $((ims_i * 2))s, imsd=${ims_pid:-$(pidof imsd)}"

# --- CONTROL TOOL ---------------------------------------------------------
# One entry point for the owner while Lineage runs (untested on device):
#   adb shell su -c 'sh /data/local/tmp/lineage_ctl.sh help'
# status (temps, top CPU users, IP for adb-over-Wi-Fi, guards), flags (every
# toggle with its value), set/unset a toggle, live density/font scale, undo
# what the crash-loop guard or the wizard skip did, tail all logs, exit.
cat > /data/local/tmp/lineage_ctl.sh <<'CTL'
#!/system/bin/sh
STAGE=${STAGE:-/data/local/tmp/lineage_stage}
GFLAGS="$STAGE/data/local/tmp/lineage_flags"
TZ_ROOT=${TZ_ROOT:-/sys/class/thermal}
if [ -z "$BB" ]; then
    BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
    [ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
fi

# name|default|meaning   (keep in sync with CHANGES_TO_TEST.md)
FLAGS_TABLE='thermal_guard|on|thermal safety valve: on, log (dry run) or 0
thermal_basecap_pct|70|CPU cap in % of max for the whole Lineage session, 0 = none
thermal_soft_c|85|C at which CPUs get capped harder
thermal_soft_secs|4|seconds above thermal_soft_c before the hard cap
thermal_softcap_pct|50|hard cap in % of max frequency, 0 = never cap
thermal_trip_c|95|C at which Lineage is exited
thermal_trip_secs|30|seconds above thermal_trip_c before exiting
thermal_batt_c|47|battery C that exits Lineage after 60 s
thermal_zones|(cpu/gpu/nsp...)|grep -E regex of zone types to watch
thermal_zones_exclude|(trip/limit)|grep -E regex of zone types to skip (trip points)
crashloop_guard|on|disable crash-looping apps in the guest: on, log or 0
crashloop_limit|5|crashes ...
crashloop_window_s|180|... within this many seconds
dexopt_throttle|on|no background dexopt, fewer dex2oat threads
gms_safety_fix|on|disable SafetyCenter API so host GMS stops crash-looping
skip_setup|on|mark provisioned and disable setup wizards
min_refresh|60.0|minimum refresh rate (Hz)
peak_refresh|120.0|peak refresh rate (Hz)
guest_cgroups|0|opt-in: give the guest cgroup v2 + app freezer (next boot)
storage_sweep_full|30|full app-storage sweep every N x 10 s
dns_heal|on|repair DNS for the current network when names fail
dns_servers|(network)|force resolvers, comma separated
net_bounce|0|allow toggling Wi-Fi as a last-resort DNS fix
density|540|guest display density (dpi)
font_scale|(unset)|guest font scale, e.g. 0.9
guest_mediaserver|on|run the Lineage mediaserver instead of the One UI one
frro_fix|on|rebuild runtime-overlay idmaps for Lineage (cutout, theme colours)
adb_framework_block|off|experiment: hide the adbd control socket from Lineage
key_escape|on|hold Volume Up + Down 3 s to return to One UI
cutout_fix|on|give the guest the One UI camera cutout (status bar position)
adb_tcp|0|adb over Wi-Fi port (e.g. 5555), next Switch
adb_watchdog_interval|1|seconds between adb watchdog checks'

guest_pid() {
    for p in $(pidof system_server 2>/dev/null); do
        ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null)
        [ -n "$ns" ] && [ "$ns" != "$(readlink /proc/self/ns/mnt)" ] && { echo "$p"; return 0; }
    done
    return 1
}
gx() {
    pid=$(guest_pid) || { echo "Lineage is not running (no guest system_server)" >&2; return 1; }
    "$BB" nsenter -t "$pid" -m "$@"
}
setflag() {
    echo "$2" > "$STAGE/$1"
    [ -d "$GFLAGS" ] && echo "$2" > "$GFLAGS/$1" && chmod 644 "$GFLAGS/$1" 2>/dev/null
    echo "$1 = $2"
}

temps() {
    for z in "$TZ_ROOT"/thermal_zone*; do
        read -r t < "$z/type" 2>/dev/null || continue
        # cpu-hw-trip-* report their fixed trip point (105 C), not a temperature
        case "$t" in *trip*|*limit*) continue ;; esac
        read -r v < "$z/temp" 2>/dev/null || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -ge 1000 ] && v=$((v / 1000))
        echo "$v $t"
    done | sort -rn | head -n "${1:-8}"
}

case "$1" in
    status|"")
        echo "== temperatures (hottest zones, C)"; temps 8 | sed 's/^/  /'
        b=$(cat /sys/class/power_supply/battery/temp 2>/dev/null); [ -n "$b" ] && echo "  battery: $((b / 10)).$((b % 10)) C"
        echo "== guards"
        for d in thermal_guard crashloop_guard adb_watchdog app_storage_loop; do
            if pgrep -f "$d.sh" >/dev/null 2>&1; then echo "  $d: running"; else echo "  $d: not running"; fi
        done
        [ -f "$STAGE/thermal_tripped" ] && echo "  LAST THERMAL TRIP: $(cat "$STAGE/thermal_tripped")"
        [ -f "$STAGE/thermal_cpufreq.saved" ] && echo "  CPUs are CAPPED by the thermal guard"
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
            [ -r "$p/scaling_max_freq" ] && echo "  $(basename "$p"): max $(cat "$p/scaling_max_freq") / hw $(cat "$p/cpuinfo_max_freq")"
        done
        [ -s "$STAGE/crashloop_disabled.txt" ] && echo "  disabled by crash-loop guard: $(tr '\n' ' ' < "$STAGE/crashloop_disabled.txt")"
        echo "== network / adb"
        ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print "  wlan0 " $2}'
        echo "  usb: config=$(getprop sys.usb.config) state=$(getprop sys.usb.state) adbd=$(getprop init.svc.adbd) tcp=$(getprop service.adb.tcp.port)"
        echo "== top CPU users"; top -b -n 1 -m 12 2>/dev/null | sed 's/^/  /'
        ;;
    temps) temps 40 ;;
    flags)
        echo "$FLAGS_TABLE" | while IFS='|' read -r n d m; do
            v=$(cat "$STAGE/$n" 2>/dev/null | tr -d '\r\n')
            printf '  %-22s %-12s (default %s) %s\n' "$n" "${v:--}" "$d" "$m"
        done ;;
    set) [ -n "$2" ] && [ -n "$3" ] || { echo "usage: set NAME VALUE"; exit 1; }; setflag "$2" "$3"
         echo "(read on the next Switch unless noted in 'flags'; live: density, fontscale)" ;;
    unset) [ -n "$2" ] || exit 1; rm -f "$STAGE/$2" "$GFLAGS/$2"; echo "$2 back to default" ;;
    density) [ -n "$2" ] || { gx /system/bin/wm density; exit; }; setflag density "$2"; gx /system/bin/wm density "$2" ;;
    fontscale) [ -n "$2" ] || exit 1; setflag font_scale "$2"; gx /system/bin/settings put system font_scale "$2" ;;
    crashloop-list) cat "$STAGE/crashloop_disabled.txt" 2>/dev/null || echo "(none)" ;;
    crashloop-undo)
        while read -r pkg; do
            [ -n "$pkg" ] && gx /system/bin/pm enable --user 0 "$pkg" >/dev/null 2>&1 && echo "re-enabled $pkg"
        done < "$STAGE/crashloop_disabled.txt" 2>/dev/null
        rm -f "$STAGE/crashloop_disabled.txt" ;;
    wizard-restore)
        setflag skip_setup 0
        for w in com.google.android.setupwizard org.lineageos.setupwizard com.android.provision; do
            gx /system/bin/pm enable --user 0 "$w" >/dev/null 2>&1 && echo "re-enabled $w"
        done ;;
    display) cat /data/local/tmp/lineage_display.txt 2>/dev/null || echo "no report yet (written 20 s after HOME)" ;;
    logs)
        for f in /data/local/tmp/thermal_guard.log /data/local/tmp/crashloop_guard.log \
                 /data/local/tmp/adb_watchdog.log /data/local/tmp/ui_activator.log "$STAGE/data/app_storage.log"; do
            echo "== $f"; tail -n "${2:-15}" "$f" 2>/dev/null
        done ;;
    exit) sh "$STAGE/return_to_oneui.sh" ;;
    *)
        echo "usage: lineage_ctl.sh <command>"
        echo "  status                 temps, guards, CPU caps, IP, adb, top CPU users"
        echo "  temps                  every thermal zone, hottest first"
        echo "  flags                  every toggle with value and default"
        echo "  set NAME VALUE | unset NAME"
        echo "  density [N]            show or set guest density live (and keep it)"
        echo "  fontscale X            set guest font scale live (and keep it)"
        echo "  crashloop-list | crashloop-undo"
        echo "  wizard-restore         re-enable the setup wizards"
        echo "  display                show the display/cutout report"
        echo "  logs [N]               tail every OneLineage log"
        echo "  exit                   return to One UI"
        ;;
esac
CTL
chmod 755 /data/local/tmp/lineage_ctl.sh

# --- ADB OVER WI-FI FALLBACK (opt-in, untested on device) -----------------
# USB adb was lost twice shortly after Lineage came up. adbd also listens on
# TCP when service.adb.tcp.port is set (what `adb tcpip 5555` does), and it
# authenticates with the same /data/misc/adb/adb_keys, so the PC that is
# already authorised can connect over Wi-Fi without any pairing:
#   echo 5555 > /data/local/tmp/lineage_stage/adb_tcp     (before Switch)
#   adb connect <phone-ip>:5555      (lineage_ctl.sh status prints the IP)
# adbd is restarted once here (a ~1 s USB blip). The original property is
# restored by return_to_oneui.sh. Anyone on the same network can reach the
# port, but cannot get in without an authorised key.
ADB_TCP=$(flag adb_tcp 0 | tr -dc '0-9')
if [ -n "$ADB_TCP" ] && [ "$ADB_TCP" -gt 0 ]; then
    save_set_prop service.adb.tcp.port "$ADB_TCP"
    setprop ctl.restart adbd 2>/dev/null || true
    echo "adb over Wi-Fi enabled on port $ADB_TCP"
fi

# --- ADB WATCHDOG ---------------------------------------------------------
# adb is the only way into the phone while Lineage is up (until wifi is
# configured), and the host adbd occasionally dies or loses the adb function
# when the container's system_server touches the USB configuration. init does
# not reliably restart it, which is the "adb randomly stopped working" symptom.
# Keep it supervised from the host namespace for the whole session; the watchdog
# is stopped again by return_to_oneui.sh.
pkill -f "adb_watchdog.sh" 2>/dev/null || true
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "adb_watchdog.sh"; then
    cat > /data/local/tmp/adb_watchdog.sh <<'ADBW'
#!/system/bin/sh
# Keeps the host adbd and the adb USB function alive (untested on device in
# this revision). Changes vs. the first version, after adb was lost twice
# shortly after Lineage came up:
#   * polls every adb_watchdog_interval seconds (default 1, was 3), so a
#     rewrite of sys.usb.config is undone before the host drops the gadget
#     for long; three getprop calls per second cost next to nothing;
#   * logs every change of sys.usb.state, so a drop is visible afterwards;
#   * counts how often it had to fight the guest's UsbDeviceManager and
#     says so if that happens more than 10 times a minute;
#   * re-asserts service.adb.tcp.port when the opt-in Wi-Fi fallback
#     (adb_tcp, see switch_to_lineage.sh) is on.
STAGE=${STAGE:-/data/local/tmp/lineage_stage}
LOG=${ADBW_LOG:-/data/local/tmp/adb_watchdog.log}
MAX_ITER=${ADBW_MAX_ITER:-0}
iv=$(cat "$STAGE/adb_watchdog_interval" 2>/dev/null | tr -dc '0-9')
[ -n "$iv" ] && [ "$iv" -gt 0 ] || iv=1
tcp=$(cat "$STAGE/adb_tcp" 2>/dev/null | tr -dc '0-9')
log() { echo "$(date) $*" >> "$LOG"; }
last_state=""
fights=0
win_start=$(date +%s)
i=0
while true; do
    sleep "$iv"
    i=$((i + 1))
    st=$(getprop init.svc.adbd)
    usb=$(getprop sys.usb.state)
    cfg=$(getprop sys.usb.config)
    if [ "$usb" != "$last_state" ]; then
        log "usb.state: '${last_state}' -> '${usb}' (config=$cfg, adbd=$st)"
        last_state=$usb
    fi
    fixed=1
    case "$cfg" in
        adb)
            # Lineage's UsbDeviceManager rewrites the config to bare "adb", which
            # Samsung's init does not know: the gadget drops and adb disappears.
            setprop sys.usb.config sec_charging,adb 2>/dev/null
            log "bare adb -> sec_charging,adb"
            ;;
        *adb*) fixed=0 ;;
        ""|none)
            setprop sys.usb.config sec_charging,adb 2>/dev/null
            log "restored sec_charging,adb (was: $cfg)"
            ;;
        *)
            setprop sys.usb.config "$cfg,adb" 2>/dev/null
            log "added adb to usb.config (was: $cfg)"
            ;;
    esac
    if [ "$fixed" = 1 ]; then
        fights=$((fights + 1))
        now=$(date +%s)
        if [ $((now - win_start)) -ge 60 ]; then
            [ "$fights" -gt 10 ] && log "WARNING: rewrote usb.config $fights times in $((now - win_start)) s; the guest keeps resetting it"
            fights=0; win_start=$now
        fi
    fi
    if [ -n "$tcp" ] && [ "$(getprop service.adb.tcp.port)" != "$tcp" ]; then
        setprop service.adb.tcp.port "$tcp" 2>/dev/null
        setprop ctl.restart adbd 2>/dev/null
        log "re-asserted adb tcp port $tcp"
    fi
    if [ "$st" != "running" ]; then
        setprop ctl.start adbd 2>/dev/null
        log "restarted adbd (was: $st, usb.state=$usb, usb.config=$cfg)"
    fi
    # Every ~15 s keep a snapshot of where adbd's threads are waiting, so an
    # adb hang (every service stuck, device still listed) can be traced after
    # returning to One UI: /data/local/tmp/adbd_threads.txt (+ .prev).
    if [ $((i % 15)) -eq 1 ]; then
        ap=$(pidof adbd 2>/dev/null)
        if [ -n "$ap" ] && [ -d "/proc/${ap%% *}/task" ]; then
            ap=${ap%% *}
            snap=${ADBW_SNAP:-/data/local/tmp/adbd_threads.txt}
            [ -f "$snap" ] && mv -f "$snap" "$snap.prev"
            {
                echo "$(date) adbd pid $ap usb.state=$usb"
                for t in /proc/$ap/task/*; do
                    c=""; w=""; s=""
                    read -r c < "$t/comm" 2>/dev/null
                    read -r w < "$t/wchan" 2>/dev/null
                    s=$(grep -m1 '^State:' "$t/status" 2>/dev/null)
                    echo "  ${t##*/} $c ${s#State:} wchan=$w"
                done
            } > "$snap" 2>/dev/null
        fi
    fi
    [ "$MAX_ITER" -gt 0 ] && [ "$i" -ge "$MAX_ITER" ] && exit 0
done
ADBW
    chmod 755 /data/local/tmp/adb_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/adb_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "adbd watchdog started (log: /data/local/tmp/adb_watchdog.log)"
fi

# --- VOLUME-KEY ESCAPE -----------------------------------------------------
# When adb is dead and Lineage misbehaves, the only way back used to be a hard
# restart. Holding Volume Up + Volume Down together for 3 s now runs
# return_to_oneui.sh. It reads key events from the host namespace with
# getevent (it does not grab the devices, Lineage still sees the keys).
# Off: echo 0 > $STAGE/key_escape    Hold time: echo 5 > $STAGE/key_escape_secs
pkill -f "key_escape.sh" 2>/dev/null || true
if is_off "$(flag key_escape on)"; then
    echo "volume-key escape disabled by $STAGE/key_escape"
else
    cat > /data/local/tmp/key_escape.sh <<'KEYESC'
#!/system/bin/sh
STAGE=${STAGE:-/data/local/tmp/lineage_stage}
LOG=${KEYESC_LOG:-/data/local/tmp/key_escape.log}
RETURN_SCRIPT=${RETURN_SCRIPT:-$STAGE/return_to_oneui.sh}
GETEVENT=${GETEVENT:-getevent -lq}
SH=${KEYESC_SH:-/system/bin/sh}
HOLD=$(cat "$STAGE/key_escape_secs" 2>/dev/null | tr -dc '0-9')
[ -n "$HOLD" ] && [ "$HOLD" -gt 0 ] || HOLD=3
BOTH=${KEYESC_STATE:-/data/local/tmp/key_escape.both}
log() { echo "$(date) $*" >> "$LOG"; }
rm -f "$BOTH"
up=0; down=0
log "key escape armed (hold ${HOLD}s)"
$GETEVENT 2>/dev/null | while read -r dev typ key val rest; do
    [ "$typ" = EV_KEY ] || continue
    case "$val" in DOWN) v=1 ;; UP) v=0 ;; *) continue ;; esac
    case "$key" in
        KEY_VOLUMEUP) up=$v ;;
        KEY_VOLUMEDOWN) down=$v ;;
        *) continue ;;
    esac
    if [ "$up" = 1 ] && [ "$down" = 1 ]; then
        if [ ! -f "$BOTH" ]; then
            tok=$$.$(date +%s)
            echo "$tok" > "$BOTH"
            # Fire only if this very press is still held after HOLD seconds.
            ( sleep "$HOLD"
              if [ "$(cat "$BOTH" 2>/dev/null)" = "$tok" ]; then
                  echo "$(date) both volume keys held ${HOLD}s -> returning to One UI" >> "$LOG"
                  rm -f "$BOTH"
                  if command -v setsid >/dev/null 2>&1; then
                      setsid "$SH" "$RETURN_SCRIPT" </dev/null >"$STAGE/key_escape_return.log" 2>&1 &
                  else
                      nohup "$SH" "$RETURN_SCRIPT" </dev/null >"$STAGE/key_escape_return.log" 2>&1 &
                  fi
              fi ) &
        fi
    else
        rm -f "$BOTH"
    fi
done
KEYESC
    chmod 755 /data/local/tmp/key_escape.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/key_escape.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/key_escape.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "volume-key escape started (hold Volume Up + Down to return to One UI)"
fi

# --- THERMAL SAFETY VALVE (untested on device) ----------------------------
# Evidence: during a Lineage session a CPU thermal zone read ~105 C, the
# battery ~44 C, and adb dropped. The guest has no thermal HAL session of its
# own; the Samsung kernel throttles by itself, but nothing stops a runaway load
# (crash loops, JIT storms) from keeping the SoC pinned at its limit for hours.
# This host-side watchdog protects the hardware:
#   * soft stage: max(cpu/gpu zones) >= thermal_soft_c (85) for 20 s
#       -> cap every cpufreq policy to thermal_softcap_pct (70 %) of its max,
#          log the top CPU users; lifted again after 60 s below soft-10.
#   * trip: >= thermal_trip_c (95) for thermal_trip_secs (30 s), or
#           >= trip+8 for 6 s, or battery >= thermal_batt_c (47) for 60 s
#       -> run return_to_oneui.sh automatically and leave a marker file
#          $STAGE/thermal_tripped plus a One UI notification.
# Log: /data/local/tmp/thermal_guard.log (capped, rotated at 256 KB).
# Toggle: echo 0   > $STAGE/thermal_guard   (off)
#         echo log > $STAGE/thermal_guard   (log only, never acts)
# Tune:   echo 97 > $STAGE/thermal_trip_c ; echo 80 > $STAGE/thermal_softcap_pct
#         echo 0  > $STAGE/thermal_softcap_pct   (never cap, only trip)
# Zones:  echo 'cpu|gpu' > $STAGE/thermal_zones   (grep -E regex on zone type)
# return_to_oneui.sh restores the original cpufreq limits if the guard dies.
pkill -f "thermal_guard.sh" 2>/dev/null || true
rm -f "$STAGE/thermal_tripped" 2>/dev/null || true
if is_off "$(flag thermal_guard on)"; then
    echo "thermal guard disabled by $STAGE/thermal_guard"
else
    cat > /data/local/tmp/thermal_guard.sh <<'THERMAL'
#!/system/bin/sh
# OneLineage thermal safety valve. Written by switch_to_lineage.sh; read the
# comment block there for the evidence and the toggles. Every path can be
# overridden from the environment so tests/ can run this against a fake sysfs.
STAGE=${STAGE:-/data/local/tmp/lineage_stage}
TZ_ROOT=${TZ_ROOT:-/sys/class/thermal}
BATT_TEMP=${BATT_TEMP:-/sys/class/power_supply/battery/temp}
CPUFREQ_ROOT=${CPUFREQ_ROOT:-/sys/devices/system/cpu/cpufreq}
LOG=${THERMAL_LOG:-/data/local/tmp/thermal_guard.log}
RETURN_SCRIPT=${RETURN_SCRIPT:-$STAGE/return_to_oneui.sh}
CAP_SAVE=${CAP_SAVE:-$STAGE/thermal_cpufreq.saved}
INTERVAL=${THERMAL_INTERVAL:-2}
MAX_ITER=${THERMAL_MAX_ITER:-0}
SH=${GUARD_SH:-/system/bin/sh}
NOTIFY_DELAY=${THERMAL_NOTIFY_DELAY:-60}

flag() {
    _v=$(cat "$STAGE/$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}
num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

load_config() {
    MODE=$(flag thermal_guard on)
    SOFT_C=$(num "$(flag thermal_soft_c 85)" 85)
    SOFT_S=$(num "$(flag thermal_soft_secs 4)" 4)
    CAP_PCT=$(num "$(flag thermal_softcap_pct 50)" 50)
    BASE_PCT=$(num "$(flag thermal_basecap_pct 70)" 70)
    [ "$BASE_PCT" -gt 100 ] && BASE_PCT=100
    [ "$BASE_PCT" -gt 0 ] && [ "$BASE_PCT" -lt 30 ] && BASE_PCT=30
    TRIP_C=$(num "$(flag thermal_trip_c 95)" 95)
    TRIP_S=$(num "$(flag thermal_trip_secs 30)" 30)
    BATT_C=$(num "$(flag thermal_batt_c 47)" 47)
    [ "$CAP_PCT" -gt 100 ] && CAP_PCT=100
    [ "$CAP_PCT" -gt 0 ] && [ "$CAP_PCT" -lt 30 ] && CAP_PCT=30
    EMERG_C=$((TRIP_C + 8))
    step=${INTERVAL:-2}; [ "$step" -gt 0 ] 2>/dev/null || step=1
    TRIP_N=$(( (TRIP_S + step - 1) / step ))
    SOFT_N=$(( (SOFT_S + step - 1) / step ))
    COOL_N=$(( (60 + step - 1) / step ))
    # 12 s, not 6: on the S26 Ultra a core sensor spikes to the 105 C
    # hardware limit for a few seconds while Lineage boots, and the kernel
    # throttles it on its own. Only a sustained reading should end the session.
    EMERG_N=$(( (12 + step - 1) / step ))
    BATT_N=$(( (60 + step - 1) / step ))
}

# Pick the zones once: their types never change, and reading only the chosen
# temp files with the shell's builtin `read` keeps every sample fork-free.
select_zones() {
    ZONES=""
    re=$(flag thermal_zones 'cpu|gpu|cpuss|gpuss|apc|nsp|aoss|ddr')
    # Verified on the S26 Ultra: cpu-hw-trip-0/1 are not sensors, they always
    # read their hardware trip point (105000). Watching them made the guard
    # "trip" 4 s after start and run return_to_oneui.sh in the middle of
    # master_prepare.sh, which tore down the rootfs (pivot_root failed, phone
    # stuck on the Samsung boot screen). Skip trip-point/limit pseudo-zones.
    # Override: echo 'trip|limit|foo' > $STAGE/thermal_zones_exclude
    ex=$(flag thermal_zones_exclude 'trip|limit')
    for z in "$TZ_ROOT"/thermal_zone*; do
        [ -r "$z/temp" ] && [ -r "$z/type" ] || continue
        read -r t < "$z/type" 2>/dev/null || continue
        if [ -n "$ex" ] && echo "$t" | grep -qiE "$ex"; then continue; fi
        if echo "$t" | grep -qiE "$re"; then
            ZONES="$ZONES $z"
        fi
    done
}

# Sets MAX_C/MAX_ZONE. Values are millidegrees on Qualcomm; anything that is
# not a sane temperature (negative, > 150 C, read error) is ignored, so a
# broken sensor cannot trip the guard.
sample() {
    MAX_C=-1; MAX_ZONE=""
    for z in $ZONES; do
        v=""
        read -r v < "$z/temp" 2>/dev/null || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -ge 1000 ] && v=$((v / 1000))
        [ "$v" -gt 150 ] && continue
        if [ "$v" -gt "$MAX_C" ]; then MAX_C=$v; MAX_ZONE=$z; fi
    done
    BATT=-1
    b=""
    if read -r b < "$BATT_TEMP" 2>/dev/null; then
        case "$b" in ''|*[!0-9]*) ;; *) BATT=$((b / 10)) ;; esac
    fi
}

zone_name() { _t=""; [ -n "$1" ] && read -r _t < "$1/type" 2>/dev/null; echo "${_t:-none}"; }

cap_cpus() { # cap_cpus [PCT]  (default: CAP_PCT)
    pct=${1:-$CAP_PCT}
    [ "$pct" -gt 0 ] || return 0
    for p in "$CPUFREQ_ROOT"/policy*; do
        [ -w "$p/scaling_max_freq" ] && [ -r "$p/cpuinfo_max_freq" ] || continue
        read -r cur < "$p/scaling_max_freq" || continue
        read -r hw < "$p/cpuinfo_max_freq" || continue
        grep -q "^$p/scaling_max_freq " "$CAP_SAVE" 2>/dev/null || \
            echo "$p/scaling_max_freq $cur" >> "$CAP_SAVE"
        target=$((hw * pct / 100))
        best=""
        if [ -r "$p/scaling_available_frequencies" ]; then
            for f in $(cat "$p/scaling_available_frequencies"); do
                case "$f" in ''|*[!0-9]*) continue ;; esac
                if [ "$f" -le "$target" ] && { [ -z "$best" ] || [ "$f" -gt "$best" ]; }; then
                    best=$f
                fi
            done
        fi
        [ -n "$best" ] || best=$target
        echo "$best" > "$p/scaling_max_freq" 2>/dev/null
        read -r now < "$p/scaling_max_freq"
        log "cap $(basename "$p"): $cur -> $best (reads back $now)"
    done
}

restore_cpus() {
    [ -f "$CAP_SAVE" ] || return 0
    while read -r f v; do
        [ -n "$f" ] && [ -n "$v" ] && echo "$v" > "$f" 2>/dev/null
    done < "$CAP_SAVE"
    rm -f "$CAP_SAVE"
    log "cpufreq limits restored"
}

top_snapshot() {
    log "top CPU users:"
    top -b -n 1 -m 12 2>/dev/null | sed 's/^/    /' >> "$LOG"
}

trip() {
    log "TRIP: $1 -> returning to One UI"
    top_snapshot
    echo "$(date) $1" > "$STAGE/thermal_tripped"
    restore_cpus
    if [ -f "$RETURN_SCRIPT" ]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid "$SH" "$RETURN_SCRIPT" </dev/null >"$STAGE/thermal_return.log" 2>&1 &
        else
            nohup "$SH" "$RETURN_SCRIPT" </dev/null >"$STAGE/thermal_return.log" 2>&1 &
        fi
        # Tell the user why Lineage vanished, once One UI's system_server is up.
        # Run detached and without this script's name in its command line, so
        # return_to_oneui.sh's pkill does not take it down.
        msg="Lineage was stopped to protect the phone: $1"
        nohup "$SH" -c "sleep $NOTIFY_DELAY; cmd notification post -S bigtext -t OneLineage onelineage_heat \"\$0\"" "$msg" </dev/null >/dev/null 2>&1 &
    else
        log "return script $RETURN_SCRIPT missing; capping CPUs to 50% instead"
        CAP_PCT=50; cap_cpus
    fi
    exit 0
}

: >> "$LOG"
load_config
select_zones
log "thermal guard start: mode=$MODE soft=${SOFT_C}C cap=${CAP_PCT}% trip=${TRIP_C}C/${TRIP_S}s emergency=${EMERG_C}C batt=${BATT_C}C zones:$(for z in $ZONES; do printf ' %s' "$(zone_name "$z")"; done)"
[ -n "$ZONES" ] || log "WARNING: no thermal zone matched; only the battery is watched"

# Baseline cap for the whole session. Evidence (S26 Ultra, One UI 9): with One
# UI's framework gone, Samsung's SSRM no longer limits CPU frequency, and a core
# sensor went from 45 C to the 105 C hardware limit about 30 s into Lineage's
# boot (CPUs ~92 % busy: system_server, GMS, Google app, Play Store). Running
# below max all the time is what SSRM would have done. The originals are saved
# and put back by restore_cpus / return_to_oneui.sh.
# Off: echo 0 > $STAGE/thermal_basecap_pct
case "$MODE" in log|dry|dryrun|dry-run) ;; *)
    if [ "$BASE_PCT" -gt 0 ]; then
        log "baseline cap ${BASE_PCT}% for the Lineage session"
        cap_cpus "$BASE_PCT"
    fi ;;
esac

hot=0; emerg=0; batt_hot=0; soft=0; cool=0; capped=0; i=0
while true; do
    i=$((i + 1))
    if [ $((i % 15)) -eq 0 ]; then
        load_config
        case "$MODE" in 0|off|false|no|disable|disabled) restore_cpus; log "disabled via flag file, exiting"; exit 0 ;; esac
    fi
    sample
    act=1
    case "$MODE" in log|dry|dryrun|dry-run) act=0 ;; esac

    if [ "$MAX_C" -ge "$TRIP_C" ]; then hot=$((hot + 1)); else hot=0; fi
    if [ "$MAX_C" -ge "$EMERG_C" ]; then emerg=$((emerg + 1)); else emerg=0; fi
    if [ "$BATT" -ge "$BATT_C" ]; then batt_hot=$((batt_hot + 1)); else batt_hot=0; fi
    if [ "$MAX_C" -ge "$SOFT_C" ]; then soft=$((soft + 1)); cool=0; else soft=0; fi
    if [ "$MAX_C" -lt $((SOFT_C - 10)) ]; then cool=$((cool + 1)); fi

    reason=""
    if [ "$emerg" -ge "$EMERG_N" ]; then
        reason="$(zone_name "$MAX_ZONE") at ${MAX_C}C (>= ${EMERG_C}C for 12 s)"
    elif [ "$hot" -ge "$TRIP_N" ]; then
        reason="$(zone_name "$MAX_ZONE") at ${MAX_C}C (>= ${TRIP_C}C for ${TRIP_S} s)"
    elif [ "$batt_hot" -ge "$BATT_N" ]; then
        reason="battery at ${BATT}C (>= ${BATT_C}C for 60 s)"
    fi
    if [ -n "$reason" ]; then
        if [ "$act" = 1 ]; then trip "$reason"; fi
        log "would trip (log-only mode): $reason"
        hot=0; emerg=0; batt_hot=0
    fi

    if [ "$soft" -ge "$SOFT_N" ] && [ "$capped" = 0 ]; then
        log "soft limit: $(zone_name "$MAX_ZONE") at ${MAX_C}C for ${SOFT_S} s"
        top_snapshot
        if [ "$act" = 1 ]; then cap_cpus; capped=1; fi
        soft=0
    fi
    if [ "$capped" = 1 ] && [ "$cool" -ge "$COOL_N" ]; then
        if [ "$BASE_PCT" -gt 0 ] && [ "$act" = 1 ]; then
            log "cooled to ${MAX_C}C for 60 s, lifting cap to the ${BASE_PCT}% baseline"
            cap_cpus "$BASE_PCT"
        else
            log "cooled to ${MAX_C}C for 60 s, lifting cap"
            restore_cpus
        fi
        capped=0; cool=0
    fi

    if [ $((i % 15)) -eq 1 ]; then
        log "max=${MAX_C}C ($(zone_name "$MAX_ZONE")) batt=${BATT}C capped=$capped"
        if [ "$(wc -c < "$LOG" 2>/dev/null)" -gt 262144 ] 2>/dev/null; then
            mv -f "$LOG" "$LOG.1"; : > "$LOG"
        fi
    fi
    [ "$MAX_ITER" -gt 0 ] && [ "$i" -ge "$MAX_ITER" ] && exit 0
    sleep "$INTERVAL"
done
THERMAL
    chmod 755 /data/local/tmp/thermal_guard.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/thermal_guard.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/thermal_guard.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "thermal guard started (log: /data/local/tmp/thermal_guard.log)"
fi

# --- DEXOPT THROTTLE (untested on device) ---------------------------------
# The guest's ART service asks the HOST artd to compile apps, and artd runs the
# host's Android 17 dex2oat. The guest's Android 16 runtime rejects that output
# (oat version mismatch), so any background or boot dexopt in the guest is
# pure heat: ~200 apps compiled on every core, with nothing usable at the end.
# Turn background dexopt off and keep dex2oat to a couple of threads while
# Lineage runs. These are host properties: the originals are saved to
# $STAGE/saved_props and return_to_oneui.sh restores them before One UI starts.
# Toggle: echo 0 > $STAGE/dexopt_throttle
if is_off "$(flag dexopt_throttle on)"; then
    echo "dexopt throttle disabled by $STAGE/dexopt_throttle"
else
    save_set_prop pm.dexopt.disable_bg_dexopt true
    save_set_prop dalvik.vm.dex2oat-threads 2
    save_set_prop dalvik.vm.bg-dex2oat-threads 1
    save_set_prop dalvik.vm.boot-dex2oat-threads 2
    echo "dexopt throttled (originals in $SAVED_PROPS)"
fi

# --- CRASH-LOOP GUARD (untested on device) --------------------------------
# Evidence: host-installed apps that do not fit the Android 16 guest restart
# forever. GMS (the Android 17 build) died every ~5 s on
#   IllegalArgumentException: Unexpected safety source: AdvancedProtection
# and every respawn JIT-compiles from scratch, because no oat file matches the
# guest runtime. A crash loop is therefore one of the most expensive things the
# guest can do. This watches the shared crash log buffer and, when one package
# crashes >= crashloop_limit (5) times within crashloop_window_s (180 s),
# disables it IN THE GUEST ONLY (`pm disable-user` writes the guest's own
# /data/system, i.e. $STAGE/data, never One UI's package state).
# Core packages (android, com.android.*, org.lineageos.*, GMS/GSF/Play Store,
# launchers, keyboards, WebView) are never disabled, only logged.
# Log: /data/local/tmp/crashloop_guard.log. Disabled packages are listed in
# $STAGE/crashloop_disabled.txt; `lineage_ctl.sh crashloop-undo` re-enables them.
# Toggle: echo 0 > $STAGE/crashloop_guard   (off)
#         echo log > $STAGE/crashloop_guard (only log what it would disable)
# Never touch a package: add its name (one per line) to $STAGE/crashloop_allow
pkill -f "crashloop_guard.sh" 2>/dev/null || true
if is_off "$(flag crashloop_guard on)"; then
    echo "crash-loop guard disabled by $STAGE/crashloop_guard"
else
    cat > /data/local/tmp/crashloop_guard.sh <<'CRASHLOOP'
#!/system/bin/sh
# OneLineage crash-loop guard. Written by switch_to_lineage.sh; read the comment
# block there for the evidence and the toggles.
STAGE=${STAGE:-/data/local/tmp/lineage_stage}
LOG=${CLG_LOG:-/data/local/tmp/crashloop_guard.log}
EVENTS=${CLG_EVENTS:-/data/local/tmp/crashloop_guard.events}
DISABLED=${CLG_DISABLED:-$STAGE/crashloop_disabled.txt}
if [ -z "$BB" ]; then
    BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
    [ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)
fi

flag() {
    _v=$(cat "$STAGE/$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}
num() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

# Run a command inside the guest's mount namespace (guest pm/am binaries).
# Refuses unless system_server lives in a different mount namespace from this
# host-side script, i.e. it really is the guest's and not One UI's.
guest() {
    _pid=$(pidof system_server 2>/dev/null | awk '{print $1}')
    [ -n "$_pid" ] || return 1
    _ns=$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null)
    [ -n "$_ns" ] && [ "$_ns" != "$(readlink /proc/self/ns/mnt 2>/dev/null)" ] || return 1
    "$BB" nsenter -t "$_pid" -m "$@"
}

protected() {
    case "$1" in
        android|system|com.android.*|org.lineageos.*|lineageos.*) return 0 ;;
        com.google.android.gms|com.google.android.gms.*|com.google.android.gsf|com.google.android.gsf.*) return 0 ;;
        com.android.vending|com.google.android.ext.*|com.google.android.permissioncontroller) return 0 ;;
        com.google.android.networkstack*|com.google.android.modulemetadata|com.google.android.packageinstaller) return 0 ;;
        com.google.android.webview|com.google.android.trichromelibrary*|com.google.android.setupwizard) return 0 ;;
        com.wewaffles.onelineage|*launcher*|*inputmethod*|*keyboard*) return 0 ;;
    esac
    grep -qxF "$1" "$STAGE/crashloop_allow" 2>/dev/null && return 0
    return 1
}

# warned PKG: true at most once per window per package, to keep the log short.
warned() {
    _now=$(date +%s)
    _last=$(awk -v p="$1" '$2 == p {t = $1} END {print t + 0}' "$EVENTS.warned" 2>/dev/null)
    [ $((_now - ${_last:-0})) -lt "$WINDOW" ] && return 0
    echo "$_now $1" >> "$EVENTS.warned"
    return 1
}

on_crash() {
    pkg=${1%%:*}
    case "$pkg" in ''|/*|*[!A-Za-z0-9._]*) return 0 ;; esac
    MODE=$(flag crashloop_guard on)
    WINDOW=$(num "$(flag crashloop_window_s 180)" 180)
    LIMIT=$(num "$(flag crashloop_limit 5)" 5)
    now=$(date +%s)
    echo "$now $pkg" >> "$EVENTS"
    awk -v now="$now" -v w="$WINDOW" '$1 >= now - w' "$EVENTS" > "$EVENTS.tmp" 2>/dev/null && mv -f "$EVENTS.tmp" "$EVENTS"
    n=$(awk -v p="$pkg" '$2 == p {c++} END {print c + 0}' "$EVENTS")
    [ "$n" -ge "$LIMIT" ] || return 0
    if protected "$pkg"; then
        warned "$pkg" || log "crash loop: $pkg crashed $n times in ${WINDOW}s (core package, left alone)"
        return 0
    fi
    case "$MODE" in
        log|dry|dryrun|dry-run)
            warned "$pkg" || log "crash loop: $pkg crashed $n times in ${WINDOW}s (log mode: would disable)"
            return 0 ;;
    esac
    if guest /system/bin/pm disable-user --user 0 "$pkg" >/dev/null 2>&1; then
        guest /system/bin/am force-stop "$pkg" >/dev/null 2>&1
        grep -qxF "$pkg" "$DISABLED" 2>/dev/null || echo "$pkg" >> "$DISABLED"
        log "crash loop: $pkg crashed $n times in ${WINDOW}s -> disabled in the guest (undo: lineage_ctl.sh crashloop-undo)"
        awk -v p="$pkg" '$2 != p' "$EVENTS" > "$EVENTS.tmp" 2>/dev/null && mv -f "$EVENTS.tmp" "$EVENTS"
    else
        warned "$pkg" || log "crash loop: $pkg crashed $n times, but pm disable-user failed"
    fi
}

: >> "$LOG"
: > "$EVENTS"
: > "$EVENTS.warned"
log "crash-loop guard start: mode=$(flag crashloop_guard on) limit=$(flag crashloop_limit 5) window=$(flag crashloop_window_s 180)s"
WINDOW=$(num "$(flag crashloop_window_s 180)" 180)
while true; do
    since=$(date '+%m-%d %H:%M:%S.000')
    logcat -b crash -v brief -T "$since" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
            *"Process: "*", PID: "*)
                p=${line#*Process: }; on_crash "${p%%,*}" ;;
            *">>> "*" <<<"*)
                p=${line#*>>> }; on_crash "${p%% <<<*}" ;;
            *"Unexpected safety source"*)
                warned safetycenter || log "GMS still hits SafetyCenter: '${line#*: }' (check gms_safety_fix / ui_activator.log)" ;;
        esac
    done
    [ -n "$CLG_ONCE" ] && exit 0
    sleep 5
done
CRASHLOOP
    chmod 755 /data/local/tmp/crashloop_guard.sh
    # Started only after the takeover is launched (see below): before that the
    # system_server on this phone is One UI's, and it must never be touched.
    START_CRASHLOOP_GUARD=1
fi

# Start persistent logcat capture for takeover diagnostics
pkill -f "takeover_logcat.log" 2>/dev/null || true
rm -f /data/local/tmp/takeover_logcat.log 2>/dev/null || true
# Rotating, capped capture (4 MB x 3 files, crash+system buffers only). The old
# unbounded `logcat -f` grew past 14 GB and kept flash/CPU busy for no reason.
rm -f /data/local/tmp/takeover_logcat.log.* 2>/dev/null || true
nohup logcat -b crash,system -r 4096 -n 3 -f /data/local/tmp/takeover_logcat.log </dev/null >/dev/null 2>&1 &
sleep 0.2
chmod 666 /data/local/tmp/takeover_logcat.log 2>/dev/null || true

# --- IMS KEEPALIVE --------------------------------------------------------
# imsd is the daemon holding the modem's IMS registration (see the IMS gate
# above). init does not always bring it back if it dies, and a dead imsd means
# SMS quietly degrades to "arrives whenever the SMSC next retries", so keep it
# supervised for the whole Lineage session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "ims_watchdog.sh"; then
    cat > /data/local/tmp/ims_watchdog.sh <<'IMSW'
#!/system/bin/sh
LOG=/data/local/tmp/ims_watchdog.log
while true; do
    sleep 60
    if ! pidof imsd >/dev/null 2>&1; then
        setprop ctl.start imsd 2>/dev/null
        echo "$(date) restarted imsd (was missing)" >> "$LOG"
    fi
done
IMSW
    chmod 755 /data/local/tmp/ims_watchdog.sh
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/ims_watchdog.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "imsd keepalive started (log: /data/local/tmp/ims_watchdog.log)"
fi

# Set permissive privapp permissions to avoid Signature|privileged fatal exceptions
set_prop ro.control_privapp_permissions log

# --- ONEUI PROTECTION & RESCUEPARTY DISABLE ---
echo "=== [1/6] Protecting OneUI Home Screen and Disabling RescueParty ==="
set_prop persist.sys.disable_rescue true
set_prop sys.rescue_boot_count 0
# Periodically reset the rescue boot counter. Samsung's init increments it on
# every zygote crash, and RescueParty triggers a factory-reset prompt (or an
# automatic reboot on some builds) once it reaches 5. The guest's system_server
# may crash and recover several times during the session; without this loop the
# counter accumulates and fires RescueParty mid-session.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "rescue_boot_suppress"; then
    nohup $BB sh -c "
while true; do
    setprop sys.rescue_boot_count 0 2>/dev/null
    sleep 15
done
" </dev/null >/dev/null 2>&1 &
    echo "rescue_boot_count suppressor started"
fi
mkdir -p "$BACKUP_DIR"
if [ -d "/data/user/0/com.sec.android.app.launcher/databases" ]; then
    cp -a /data/user/0/com.sec.android.app.launcher/databases/* "$BACKUP_DIR/" 2>/dev/null || true
    echo "One UI Home databases snapshotted to $BACKUP_DIR"
fi

# --- AUDIO LOW LATENCY TUNING ---
# Deep buffer must stay OFF. Tested live: with audio.deep_buffer.media=true the
# deep-buffer output opens but never consumes, and an AudioTrack write blocks
# forever (app_process hung in futex_wait). The 20 ms normal path is the one
# that actually works; a streamed tone on it is clean (0 underruns, 0 late
# writes). Offload stays off: no working vendor DSP session in the container.
echo "=== [2/6] Configuring Low-Latency Audio ==="
set_prop audio.offload.disable 1
set_prop audio.deep_buffer.media false
set_prop audio.offload.video false
set_prop vendor.audio.offload.track.enable false

# --- NETWORK BPF FIREWALL & DNS BYPASS ---
echo "=== [3/6] Configuring Network BPF Filters ==="
bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_configuration_map key hex 00 00 00 00 value hex 00 00 00 00 2>/dev/null || true
chmod 666 /dev/socket/dnsproxyd 2>/dev/null || true

# --- VERIFY STAGING ENVIRONMENT ---
echo "=== [4/6] Verifying Staging Environment ==="
if [ ! -f "$STAGE/system.raw" ]; then
    echo "ERROR: LineageOS system image ($STAGE/system.raw) not found!"
    echo "Please tap 'Download LineageOS' in the app first."
    exit 1
fi

# Ensure all scripts and engine binaries exist in $STAGE
mkdir -p "$STAGE/data"
APP_FILES="/data/user/0/com.wewaffles.onelineage/files"
if [ -d "$APP_FILES" ]; then
    for f in "$APP_FILES"/*; do
        bf=$(basename "$f")
        # Do not overwrite files in STAGE if already present
        [ -f "$STAGE/$bf" ] || cp -f "$f" "$STAGE/$bf" 2>/dev/null || true
    done
fi
chmod 755 "$STAGE"/*.sh "$STAGE/zygote_exec" 2>/dev/null || true

# Toggle files for scripts that run INSIDE the guest (net_fix.sh,
# app_storage_loop.sh) cannot be read from $STAGE after the pivot, so mirror the
# small ones into the guest's /data/local/tmp/lineage_flags. Only plain files
# with lowercase names, no dot and <= 256 bytes are copied (density,
# net_bounce, ...), never images or scripts. lineage_ctl.sh writes both copies.
GFLAGS="$STAGE/data/local/tmp/lineage_flags"
rm -rf "$GFLAGS" 2>/dev/null
mkdir -p "$GFLAGS"
for f in "$STAGE"/*; do
    b=${f##*/}
    case "$b" in *[!a-z0-9_]*) continue ;; esac
    [ -f "$f" ] && [ "$(wc -c < "$f")" -le 256 ] && cp -f "$f" "$GFLAGS/$b" 2>/dev/null
done
chmod 755 "$GFLAGS" 2>/dev/null
chmod 644 "$GFLAGS"/* 2>/dev/null

# --- CAMERA CUTOUT (status bar position) ----------------------------------
# Verified on an S26 Ultra: the GSI enables its noCutoutGSI overlay, so the
# guest's DisplayCutout is empty and its status bar is 95 px tall, while the
# punch hole is 80 x 139 px at the top centre. Clock and icons are laid out as
# if there were no hole. One UI reports the hole as a path in dp at ITS
# density ("M 0,0 H -10.67 V 37.07 H 10.67 V 0 H 0 Z @dp", density 3.75);
# the guest runs at another density, so convert it to pixels here, while One
# UI is still up, and let ui_activator apply it as a fabricated overlay.
# Off: echo 0 > $STAGE/cutout_fix   Manual spec (px): $STAGE/cutout_spec
rm -f "$STAGE/cutout_spec.auto" 2>/dev/null
if ! is_off "$(flag cutout_fix on)"; then
    _dw=$(dumpsys window displays 2>/dev/null)
    _spec=$(echo "$_dw" | grep -o -m1 'cutoutSpec={[^}]*}' | sed 's/^cutoutSpec={//; s/}$//')
    _dens=$(echo "$_dw" | grep -o -m1 'density={[0-9.]*}' | tr -dc '0-9.')
    case "$_spec" in
        *@dp*)
            if [ -n "$_dens" ]; then
                echo "$_spec" | sed 's/@dp//' | awk -v d="$_dens" '{
                    out = ""
                    for (i = 1; i <= NF; i++) {
                        n = split($i, part, ",")
                        tok = ""
                        for (j = 1; j <= n; j++) {
                            v = part[j]
                            if (v ~ /^-?[0-9.]+$/) v = sprintf("%.0f", v * d)
                            tok = tok (j > 1 ? "," : "") v
                        }
                        out = out (i > 1 ? " " : "") tok
                    }
                    print out
                }' > "$STAGE/cutout_spec.auto"
            fi ;;
        "") ;;
        *) echo "$_spec" > "$STAGE/cutout_spec.auto" ;;
    esac
    [ -s "$STAGE/cutout_spec.auto" ] && echo "host cutout (px): $(cat "$STAGE/cutout_spec.auto")"
fi

# --- MOUNT PREPARATION ---
echo "=== [5/6] Executing Mount Hierarchy Preparation ==="
/system/bin/sh "$STAGE/master_prepare.sh"
PREP_RET=$?
if [ $PREP_RET -ne 0 ]; then
    echo "ERROR: master_prepare.sh failed (code $PREP_RET)!"
    exit 1
fi

# --- STOP HOST DAEMONS & LAUNCH CONTAINER ---
echo "=== [6/6] Launching LineageOS Takeover Daemon ==="
pkill -f "while true; do [ \"\$(getprop init.svc.zygote)\"" 2>/dev/null || true
pkill -f "while true; do for p in \\\$(pidof audioserver cameraserver)" 2>/dev/null || true
setprop ctl.stop zygote
setprop ctl.stop zygote_next 2>/dev/null || true
setprop ctl.stop surfaceflinger
# audioserver/cameraserver are deliberately left running. The guest shares this
# binder namespace, and its AudioService.<init> -> AudioDeviceBroker.init ->
# AudioSystem::addAudioPortCallback waits on media.audiopolicy with no timeout:
# with no audio policy service registered, system_server's main thread hangs
# (~2 min watchdog stall, boot stuck on the animation). Freezing them with
# kill -STOP is the worst of both worlds - the binder registration survives
# while the process can never answer.
kill -9 $(pidof surfaceflinger) 2>/dev/null || true
kill -9 $(pidof bootanimation) 2>/dev/null || true
kill -9 $(pidof app_process64) 2>/dev/null || true
kill -9 $(pidof zygote_exec) 2>/dev/null || true
kill -9 $(pidof zygote64) $(pidof zygote_next) 2>/dev/null || true
kill -9 $(pidof system_server) 2>/dev/null || true
sleep 1

# Stop the HOST media codec stack. The guest's libmedia binds `media.codec` from
# the shared servicemanager, i.e. Samsung's mediaserver - whose IMediaCodecList
# AIDL hash differs from the GSI's. The reply parcel is then parsed as garbage
# ("enforceInterface() expected 'android.gui.IGraphicBufferProducer' but read
# 'android.media.IMediaCodecList'", "AString: ctor got NULL"), which yields a
# codec list with a bogus length, so findCodecForFormat -> codecHandlesFormat
# spins ~2M times inside both system_server and SystemUI, round-tripping to
# mediaserver each iteration. That is the 125% CPU / constant overheating / GB
# of logcat. With no media.codec registered the lookup fails fast and the list
# is empty. Audio is unaffected (audioserver is its own process and is kept).
# mediaserver must stay UP even though the codec list is unusable: apps play
# short sounds with MediaPlayer, and MediaPlayer.setDataSource blocks in
# IMediaDeathNotifier::getMediaPlayerService when "media.player" is missing.
# That is a 5 s main-thread stall -> ANR -> force-close: Messaging died on every
# send because of its "sent" sound (playSentSound), and any app doing the same
# would die too. Keep only the codec processes down, which is what causes the
# spin described above.
setprop ctl.start media 2>/dev/null || true
for svc in media.codec media.metrics; do
    setprop ctl.stop $svc 2>/dev/null || true
done
kill -9 $(pidof media.codec) $(pidof media.metrics) 2>/dev/null || true

# Samsung's init restarts media.codec on demand whenever any binder client
# requests IMediaCodecList. The one-shot kill above is not enough: within
# seconds the guest's system_server (or SystemUI) triggers a new lookup, init
# respawns media.codec, and the AIDL hash mismatch drives the ~2M-iteration
# codecHandlesFormat spin all over again. That spin saturates the system_server
# binder thread pool, hits its 60-second watchdog, and kills system_server —
# which is what "Lineage reboots / restarts after ~1 minute" looks like. Keep a
# daemon that immediately kills any media.codec that init brings back.
if ! ps -ef 2>/dev/null | grep -v grep | grep -q "media_codec_suppress"; then
    nohup $BB sh -c "
while true; do
    sleep 3
    if pidof media.codec >/dev/null 2>&1; then
        setprop ctl.stop media.codec 2>/dev/null || true
        kill -9 \$(pidof media.codec) 2>/dev/null || true
    fi
    if pidof media.metrics >/dev/null 2>&1; then
        setprop ctl.stop media.metrics 2>/dev/null || true
        kill -9 \$(pidof media.metrics) 2>/dev/null || true
    fi
done
" </dev/null >/dev/null 2>&1 &
    echo "media.codec suppressor started"
fi

# Same handover for wifi. The guest's WifiService binds IWificond (service
# "wifinl80211") and drives the vendor HAL through it. Samsung's wificond is
# still holding the client interface that One UI's (now dead) WifiService
# created, so every startScan() comes back "status: -1" and the framework sees
# "No scan results" - wifi looks broken but only the scanner is wedged. The
# GSI's own wificond starts in master_inner.sh and scans fine against the same
# vendor HAL.
setprop ctl.stop wificond 2>/dev/null || true
kill -9 $(pidof wificond) 2>/dev/null || true
sleep 1

# mediaserver. Verified on an S26 Ultra (One UI 9): with only media.codec down,
# Lineage still gets its codec list from One UI's mediaserver ("media.player",
# Android 17). SystemUI and system_server sit in
#   MediaCodec::CreateByType -> MediaCodecList::findMatchingCodecs ->
#   BpMediaCodecList::getCodecInfo -> MediaCodecInfo::FromParcel
# in a loop, mediaserver's binder threads burn ~120 % CPU, and both clients
# grow ~100 MB of native heap per minute until they abort with "Scudo ERROR:
# internal map failure (Out of memory)" after ~30 min (the freezes). Stop One
# UI's mediaserver (init service "media") and let master_inner.sh start the
# GSI's own, which serves the codec list in Lineage's format.
# return_to_oneui.sh kills the guest copy and starts "media" again.
# Off: echo 0 > $STAGE/guest_mediaserver
if is_off "$(flag guest_mediaserver on)"; then
    echo "guest mediaserver disabled, keeping One UI's"
else
    setprop ctl.stop media 2>/dev/null || true
    kill -9 $(pidof mediaserver) 2>/dev/null || true
    echo "One UI mediaserver stopped (Lineage starts its own)"
fi

# Suppress the host zygote only, so Samsung init does not resurrect it
nohup $BB sh -c "while true; do [ \"\$(getprop init.svc.zygote)\" = \"running\" ] && setprop ctl.stop zygote; [ \"\$(getprop init.svc.zygote_next)\" = \"running\" ] && setprop ctl.stop zygote_next; sleep 1; done" </dev/null >/dev/null 2>&1 &

# Copy inner script and zygote_exec into container data partition
cp -f "$STAGE/master_inner.sh" "$STAGE/data/master_inner.sh"
chmod 755 "$STAGE/data/master_inner.sh"
cp -f "$STAGE/zygote_exec" "$STAGE/data/zygote_exec"
chmod 755 "$STAGE/data/zygote_exec"

# Launch takeover inside isolated mount namespace
set_prop sys.boot_completed 0
$BB unshare -m $BB sh "$STAGE/data/master_inner.sh" </dev/null >"$STAGE/data/takeover.log" 2>&1 &
TAKEOVER_PID=$!
echo "Takeover daemon PID: $TAKEOVER_PID"

if [ "${START_CRASHLOOP_GUARD:-0}" = 1 ]; then
    if command -v setsid >/dev/null 2>&1; then
        setsid /system/bin/sh /data/local/tmp/crashloop_guard.sh </dev/null >/dev/null 2>&1 &
    else
        nohup /system/bin/sh /data/local/tmp/crashloop_guard.sh </dev/null >/dev/null 2>&1 &
    fi
    echo "crash-loop guard started (log: /data/local/tmp/crashloop_guard.log)"
fi

# Start UI Activator daemon
cat > /data/local/tmp/ui_activator.sh <<'UIACT'
#!/system/bin/sh
STAGE="/data/local/tmp/lineage_stage"
BB=$(which busybox 2>/dev/null || echo "/data/adb/ksu/bin/busybox")
[ -x "$BB" ] || BB=$(find /data/adb /system /data -name busybox 2>/dev/null | head -n 1)

flag() {
    _v=$(cat "$STAGE/$1" 2>/dev/null | tr -d ' \t\r\n')
    if [ -n "$_v" ]; then echo "$_v"; else echo "$2"; fi
}
is_off() { case "$1" in 0|off|false|no|disable|disabled) return 0 ;; esac; return 1; }
gx() { $BB nsenter -t "$PID" -m "$@"; }

# Work that should land as early as possible in the guest boot, retried on
# every 2 s poll until it sticks (untested on device).
#
# GMS SafetyCenter: the host's Android 17 GMS crash-loops in the guest every
# ~5 s on "IllegalArgumentException: Unexpected safety source:
# AdvancedProtection" from SafetyCenterManager.setSafetySourceData. In the
# Android 16 SafetyCenterService, setSafetySourceData returns early when the
# Safety Center API is disabled, BEFORE it validates the source id, and the
# privacy/safety_center_is_enabled DeviceConfig flag still overrides the U+
# default of "enabled". The old code set the flag once, ~45 s into boot, after
# the loop had been running for a while, and GMS's own flag sync can set it
# back to true. Now: set it as soon as the settings provider answers, freeze
# DeviceConfig sync so GMS cannot undo it, and read it back.
# Toggle: echo 0 > $STAGE/gms_safety_fix
SAFETY_DONE=0
#
# Setup wizard: after Wi-Fi was joined inside the wizard it sat on "checking
# for updates" / internet forever (it waits on GMS, which is crash-looping, and
# on network validation, see net_fix.sh). A spinning wizard also burns CPU.
# Mark the device provisioned and disable the wizard packages in the GUEST
# (guest /data/system only) before the launcher is started, then force HOME.
# Undo: echo 0 > $STAGE/skip_setup, then in the guest
#   pm enable com.google.android.setupwizard (and/or org.lineageos.setupwizard)
WIZARD_DONE=0
skip_setup() {
    is_off "$(flag skip_setup on)" && { WIZARD_DONE=1; return 0; }
    gx /system/bin/settings put global device_provisioned 1 >/dev/null 2>&1 || return 1
    gx /system/bin/settings put secure user_setup_complete 1 >/dev/null 2>&1 || return 1
    [ "$(gx /system/bin/settings get secure user_setup_complete 2>/dev/null)" = "1" ] || return 1
    for wiz in com.google.android.setupwizard org.lineageos.setupwizard com.android.provision; do
        gx /system/bin/pm path "$wiz" >/dev/null 2>&1 || continue
        gx /system/bin/pm disable-user --user 0 "$wiz" >/dev/null 2>&1 && \
            echo "[UI Activator] setup wizard $wiz disabled in the guest"
        gx /system/bin/am force-stop "$wiz" >/dev/null 2>&1
    done
    WIZARD_DONE=1
    echo "[UI Activator] device marked provisioned, setup wizard skipped"
}

# Give the guest the host's punch-hole cutout (see "CAMERA CUTOUT" in the host
# part). A fabricated overlay on android sets config_mainBuiltInDisplayCutout
# and its rect approximation; the GSI's noCutout overlays are switched off so
# ours wins. Everything is logged so a wrong result can be undone with
# `cmd overlay disable` or by turning cutout_fix off.
apply_cutout() {
    is_off "$(flag cutout_fix on)" && { echo "[UI Activator] cutout fix off"; return 0; }
    spec=$(cat "$STAGE/cutout_spec" 2>/dev/null)
    [ -n "$spec" ] || spec=$(cat "$STAGE/cutout_spec.auto" 2>/dev/null)
    [ -n "$spec" ] || { echo "[UI Activator] no cutout spec, skipping"; return 0; }
    for res in config_mainBuiltInDisplayCutout config_mainBuiltInDisplayCutoutRectApproximation; do
        o=$(gx /system/bin/cmd overlay fabricate --target android --name "ol_$res" \
            "android:string/$res" 0x03 "$spec" 2>&1)
        echo "[UI Activator] fabricate $res: ${o:-ok}"
    done
    for ov in $(gx /system/bin/cmd overlay list android 2>/dev/null | grep -o '[^ ]*:ol_config_[A-Za-z]*'); do
        o=$(gx /system/bin/cmd overlay enable "$ov" 2>&1)
        echo "[UI Activator] enable $ov: ${o:-ok}"
    done
    for ov in com.android.internal.display.cutout.emulation.noCutoutGSI \
              com.android.internal.display.cutout.emulation.noCutout; do
        gx /system/bin/cmd overlay disable "$ov" >/dev/null 2>&1 && \
            echo "[UI Activator] disabled $ov"
    done
    echo "[UI Activator] cutout spec applied: $spec"
    fix_frro_idmaps restart
}

# Runtime overlays (fabricated .frro: our cutout, SystemUI's wallpaper colours)
# never applied in Lineage. Verified on an S26 Ultra: Lineage's system_server
# reaches One UI's Android 17 idmap2d through the shared servicemanager, which
# writes the .frro files and idmaps into One UI's /data/resource-cache in its
# own format ("failed to parse idmap header"). Lineage never sees usable
# copies, so `cmd overlay lookup` returned the GSI's empty cutout. Copy the
# .frro files into Lineage's /data, build Lineage-format idmaps with Lineage's
# own idmap2 (as master_inner.sh already does for the gesture-nav overlay),
# re-enable the overlays and restart SystemUI so the status bar is laid out
# again. Off: echo 0 > $STAGE/frro_fix
fix_frro_idmaps() {
    is_off "$(flag frro_fix on)" && return 0
    gcache="$STAGE/data/resource-cache"
    mkdir -p "$gcache"
    n=0
    for f in /data/resource-cache/*.frro; do
        [ -f "$f" ] || continue
        cp -f "$f" "$gcache/" 2>/dev/null && n=$((n + 1))
    done
    chown system:system "$gcache"/*.frro 2>/dev/null
    chmod 644 "$gcache"/*.frro 2>/dev/null
    ok=0; bad=0
    for f in "$gcache"/*.frro; do
        [ -f "$f" ] || continue
        b=${f##*/}; gpath="/data/resource-cache/$b"
        name=${b%.frro}; name=${name#*-}; name=${name%-*}
        idm="/data/resource-cache/data@resource-cache@$b@idmap"
        if gx /system/bin/idmap2 create --target-apk-path /system/framework/framework-res.apk \
                --overlay-apk-path "$gpath" --overlay-name "$name" --idmap-path "$idm" \
                --ignore-overlayable >/dev/null 2>&1; then
            ok=$((ok + 1))
        else
            bad=$((bad + 1))
        fi
    done
    chown system:system "$gcache"/*@idmap 2>/dev/null
    chmod 644 "$gcache"/*@idmap 2>/dev/null
    for ov in $(gx /system/bin/cmd overlay list android 2>/dev/null | grep -o '[^ ]*:ol_config_[A-Za-z]*'); do
        gx /system/bin/cmd overlay disable "$ov" >/dev/null 2>&1
        gx /system/bin/cmd overlay enable "$ov" >/dev/null 2>&1
    done
    echo "[UI Activator] frro: copied $n, idmaps ok=$ok failed=$bad"
    if [ "$1" = restart ]; then
        sp=$(gx /system/bin/pidof com.android.systemui 2>/dev/null)
        [ -n "$sp" ] && kill $sp 2>/dev/null && echo "[UI Activator] SystemUI restarted to apply the cutout"
    fi
}

# Status bar / shade size: the bar height is max(cutout safe inset, 24 dp).
# The host's punch-hole cutout is ~139 px tall, i.e. ~41 dp at 540 dpi, so the
# cutout - not the density - probably decides the bar height, while icons and
# text follow the density. Which direction "off" means is not known yet, so
# instead of guessing, record what the guest actually computes, once the UI
# is up, to /data/local/tmp/lineage_display.txt (no personal data in it).
display_report() {
    sleep 20
    ( sleep 40; fix_frro_idmaps ) &
    out=/data/local/tmp/lineage_display.txt
    {
        echo "== $(date) density flag=$(flag density 540) font_scale flag=$(flag font_scale unset)"
        echo "== wm"; gx /system/bin/wm size; gx /system/bin/wm density
        echo "== settings"
        for k in font_scale min_refresh_rate peak_refresh_rate; do
            echo "system/$k=$(gx /system/bin/settings get system $k 2>/dev/null)"
        done
        echo "secure/display_cutout_mode=$(gx /system/bin/settings get secure display_cutout_mode 2>/dev/null)"
        echo "== display cutout (dumpsys display)"
        gx /system/bin/dumpsys display 2>/dev/null | grep -iE 'cutout|DisplayDeviceInfo\{' | head -n 20
        echo "== window insets (dumpsys window)"
        gx /system/bin/dumpsys window 2>/dev/null | grep -iE 'cutout|statusBars|InsetsSource|mStableInsets|StatusBar.*frame' | head -n 40
        echo "== overlays"
        gx /system/bin/cmd overlay list 2>/dev/null | grep -iE 'cutout|navbar|statusbar|android$' | head -n 30
        echo "== guest cgroup v2 visible? (heat diagnosis)"
        gx /system/bin/ls /sys/fs/cgroup 2>/dev/null | head -n 5 || echo "(empty)"
    } > "$out" 2>&1
    chmod 644 "$out" 2>/dev/null
    echo "[UI Activator] display report written to $out"
}

early_tweaks() {
    [ "$WIZARD_DONE" = 1 ] || skip_setup
    if [ "$SAFETY_DONE" = 0 ]; then
        if is_off "$(flag gms_safety_fix on)"; then
            SAFETY_DONE=1
        elif gx /system/bin/device_config put privacy safety_center_is_enabled false >/dev/null 2>&1; then
            gx /system/bin/device_config set_sync_disabled_for_tests persistent >/dev/null 2>&1
            if [ "$(gx /system/bin/device_config get privacy safety_center_is_enabled 2>/dev/null)" = "false" ]; then
                SAFETY_DONE=1
                echo "[UI Activator] SafetyCenter API disabled for GMS (sync mode: $(gx /system/bin/device_config get_sync_disabled_for_tests 2>/dev/null))"
            fi
        fi
    fi
}

ready_count=0
while true; do
    sleep 2
    PID=$(pidof system_server | awk '{print $1}')
    if [ -n "$PID" ]; then
        echo "[UI Activator] system_server PID=$PID alive, checking readiness..."
        early_tweaks
        is_ready=0
        if $BB nsenter -t $PID -m /system/bin/dumpsys window 2>/dev/null | grep -E -q 'mStatusBar|StatusBar'; then
            echo "[UI Activator] StatusBar found in WindowManager!"
            is_ready=1
        elif [ "$($BB nsenter -t $PID -m /system/bin/getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            echo "[UI Activator] sys.boot_completed is 1!"
            is_ready=1
        fi

        ready_count=$((ready_count + 1))
        # Failsafe: if system_server has been up for 45s, dismiss boot animation
        if [ "$ready_count" -ge 22 ]; then
            echo "[UI Activator] Failsafe: system_server up for 45s, proceeding to activate UI..."
            is_ready=1
        fi
    else
        ready_count=$((ready_count + 1))
        echo "[UI Activator] Waiting for system_server... (${ready_count} attempts)"
        if [ "$ready_count" -ge 30 ]; then
            echo "[UI Activator] ERROR: system_server never appeared after 60s!"
            break
        fi
    fi

        if [ "$is_ready" = "1" ]; then
            echo '[UI Activator] WindowManager is ready! Dismissing bootanim and unlocking...'
            setprop service.bootanim.exit 1
            kill -9 $(pidof bootanimation) 2>/dev/null
            sleep 1
            # Display size: the guest inherits the panel's native 600 dpi (384 dp wide),
            # which makes AOSP UI oversized. Apply a saner density. Override by writing
            # a number to /data/local/tmp/lineage_stage/density (e.g. 500, 540, 560).
            LDENS=$(cat "$STAGE/density" 2>/dev/null | tr -dc '0-9')
            [ -n "$LDENS" ] || LDENS=540
            $BB nsenter -t $PID -m /system/bin/wm density "$LDENS" 2>/dev/null || true
            apply_cutout
            # Text size independent of density (status bar clock, shade, apps).
            # Unset by default. e.g. echo 0.9 > $STAGE/font_scale
            LFS=$(flag font_scale "")
            case "$LFS" in
                ''|*[!0-9.]*) ;;
                *) $BB nsenter -t $PID -m /system/bin/settings put system font_scale "$LFS" 2>/dev/null && \
                       echo "[UI Activator] font_scale=$LFS" ;;
            esac
            # GMS SafetyCenter crash loop: see early_tweaks above (retried here in
            # case the settings provider was not up during the early polls).
            early_tweaks
            [ "$SAFETY_DONE" = 1 ] || echo "[UI Activator] WARNING: could not disable the SafetyCenter API yet"
            # Keep adb on and never auto-revoke authorisations
            $BB nsenter -t $PID -m /system/bin/settings put global adb_enabled 1 2>/dev/null || true
            $BB nsenter -t $PID -m /system/bin/settings put global adb_allowed_connection_time 0 2>/dev/null || true
            $BB nsenter -t $PID -m /system/bin/settings put global private_dns_mode off 2>/dev/null || true
            $BB nsenter -t $PID -m /system/bin/svc power stayon true
            $BB nsenter -t $PID -m /system/bin/settings put global stay_on_while_plugged_in 7
            $BB nsenter -t $PID -m /system/bin/settings put system screen_off_timeout 2147483647
            $BB nsenter -t $PID -m /system/bin/settings put system haptic_feedback_enabled 1
            # Refresh rate. min_refresh_rate used to be forced to 120, which keeps
            # the panel, SurfaceFlinger and the GPU at 120 Hz even on a static
            # screen that never turns off (stayon above): steady heat for no
            # benefit. Let it idle down to 60 Hz; scrolling still runs at the peak.
            # Toggle: echo 120 > $STAGE/min_refresh (old behaviour), and
            #         $STAGE/peak_refresh for the upper bound (default 120).
            $BB nsenter -t $PID -m /system/bin/settings put system peak_refresh_rate "$(flag peak_refresh 120.0)"
            $BB nsenter -t $PID -m /system/bin/settings put system min_refresh_rate "$(flag min_refresh 60.0)"
            # Cached-app freezer. Only meaningful when the guest can see the
            # cgroup v2 tree (opt-in guest_cgroups, see master_prepare.sh).
            case "$(flag guest_cgroups 0)" in
                1|on|true|yes)
                    $BB nsenter -t $PID -m /system/bin/settings put global cached_apps_freezer enabled 2>/dev/null || true
                    $BB nsenter -t $PID -m /system/bin/device_config put activity_manager_native_boot use_freezer true 2>/dev/null || true
                    echo "[UI Activator] cached-app freezer enabled (guest_cgroups=1)"
                    ;;
            esac
            # Background dexopt in the guest is wasted work (see the dexopt
            # throttle in switch_to_lineage.sh); cancel anything already queued.
            if ! is_off "$(flag dexopt_throttle on)"; then
                # (Not "bg-dexopt-job --cancel": builds without that flag would
                # treat it as a package list and START the job.)
                $BB nsenter -t $PID -m /system/bin/pm cancel-bg-dexopt-job >/dev/null 2>&1 || true
            fi
            $BB nsenter -t $PID -m /system/bin/cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.gestural 2>/dev/null || true
            $BB nsenter -t $PID -m /system/bin/settings put secure navigation_mode 2 2>/dev/null || true
            $BB nsenter -t $PID -m /system/bin/pm disable android.ext.services/android.ext.services.notification.Assistant 2>/dev/null || true
            # Setup wizard skip must land before HOME is started below.
            [ "$WIZARD_DONE" = 1 ] || skip_setup || echo "[UI Activator] WARNING: setup wizard skip failed (settings provider not ready?)"
            $BB nsenter -t $PID -m /system/bin/input keyevent 224
            $BB nsenter -t $PID -m /system/bin/input keyevent 82
            $BB nsenter -t $PID -m /system/bin/am unlock-user 0
            $BB nsenter -t $PID -m /system/bin/am start -a android.intent.action.MAIN -c android.intent.category.HOME
            echo '[UI Activator] Home activated!'
            display_report &
            echo '[UI Activator] Creating missing app data dirs...'
            $BB nsenter -t $PID -m /system/bin/sh /data/local/tmp/fix_app_dirs.sh 2>/dev/null || true

            # Install microG if requested
            if [ -f "$STAGE/install_microg.flag" ]; then
                echo '[UI Activator] Installing microG components...'
                for apk in "$STAGE/GmsCore.apk" "$STAGE/FakeStore.apk" /data/local/tmp/GmsCore.apk /data/local/tmp/FakeStore.apk; do
                    if [ -f "$apk" ]; then
                        echo "[UI Activator] Installing $apk..."
                        $BB nsenter -t $PID -m /system/bin/pm install -r -g "$apk" 2>/dev/null || true
                    fi
                done
                rm -f "$STAGE/install_microg.flag" 2>/dev/null || true
            fi

            # Populate network permissions for all installed packages
            for uid in $($BB nsenter -t $PID -m /system/bin/pm list packages -U 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | sort -u); do
                [ -n "$uid" ] || continue
                b0=$(printf "%02x" $((uid & 0xff)))
                b1=$(printf "%02x" $(((uid >> 8) & 0xff)))
                b2=$(printf "%02x" $(((uid >> 16) & 0xff)))
                b3=$(printf "%02x" $(((uid >> 24) & 0xff)))
                bpftool map update pinned /sys/fs/bpf/netd_shared/map_netd_uid_permission_map key hex $b0 $b1 $b2 $b3 value hex 0c 2>/dev/null || true
            done

            # Ensure default routing
            DEF_IF=$(ip route | grep -o 'dev [^ ]*' | head -n 1 | awk '{print $2}')
            [ -n "$DEF_IF" ] && ip route add default dev "$DEF_IF" 2>/dev/null || true

            # Mount emulated primary storage
            _sm_ok=0
            for _attempt in 1 2 3 4 5; do
                $BB nsenter -t $PID -m /system/bin/sm mount "emulated;0" 2>/dev/null && _sm_ok=1 && break
                sleep 2
            done
            echo "[UI Activator] sm mount result: _sm_ok=$_sm_ok (attempts: $_attempt)"
            break
        fi
done
UIACT
chmod 755 /data/local/tmp/ui_activator.sh
if command -v setsid >/dev/null 2>&1; then
    setsid /system/bin/sh /data/local/tmp/ui_activator.sh </dev/null >/data/local/tmp/ui_activator.log 2>&1 &
else
    nohup /system/bin/sh /data/local/tmp/ui_activator.sh </dev/null >/data/local/tmp/ui_activator.log 2>&1 &
fi
echo "ui_activator started (log: /data/local/tmp/ui_activator.log)"

echo "=== TAKEOVER LAUNCHED SUCCESSFULLY ==="
