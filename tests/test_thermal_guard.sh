#!/bin/sh
# Unit tests for the thermal safety valve embedded in switch_to_lineage.sh.
. "$(dirname "$0")/lib.sh"
echo "thermal_guard"
GUARD=$(extract switch_to_lineage__THERMAL)

# mkzone ROOT N TYPE TEMP
mkzone() { mkdir -p "$1/thermal/thermal_zone$2"; echo "$3" > "$1/thermal/thermal_zone$2/type"; echo "$4" > "$1/thermal/thermal_zone$2/temp"; }
settemp() { echo "$3" > "$1/thermal/thermal_zone$2/temp"; }

setup() {
    T=$(tmpdir)
    mkdir -p "$T/stage" "$T/cpufreq/policy0" "$T/cpufreq/policy6"
    for p in policy0 policy6; do
        echo 3000000 > "$T/cpufreq/$p/cpuinfo_max_freq"
        echo 3000000 > "$T/cpufreq/$p/scaling_max_freq"
        echo "1000000 2000000 2500000 3000000" > "$T/cpufreq/$p/scaling_available_frequencies"
    done
    echo 350 > "$T/batt_temp"
    printf '#!/bin/sh\necho returned > "%s/returned"\n' "$T" > "$T/stage/return_to_oneui.sh"
    mkzone "$T" 0 cpu-0-0-0 45000
    mkzone "$T" 1 gpuss-0 44000
    mkzone "$T" 2 battery 99000      # not a SoC zone: must be ignored
    mkzone "$T" 3 pm8550_tz 120000   # PMIC zone: must be ignored
}

run_guard() { # run_guard ITERATIONS
    STAGE="$T/stage" TZ_ROOT="$T/thermal" BATT_TEMP="$T/batt_temp" \
    CPUFREQ_ROOT="$T/cpufreq" THERMAL_LOG="$T/log" THERMAL_INTERVAL=1 \
    THERMAL_MAX_ITER="$1" GUARD_SH=sh THERMAL_NOTIFY_DELAY=0 \
    PATH="$PATH" "$TEST_SH" -c 'sleep() { :; }; . "$0"' "$GUARD" >/dev/null 2>&1
    # setsid/nohup children are asynchronous
    i=0; while [ $i -lt 20 ] && [ -f "$T/stage/thermal_tripped" ] && [ ! -f "$T/returned" ]; do sleep 0.1; i=$((i + 1)); done
}

setup
run_guard 40
assert_no_file "$T/returned" "cool phone: no trip"
assert_no_file "$T/stage/thermal_cpufreq.saved" "cool phone: no cap"
assert_grep "thermal guard start: mode=on" "$T/log" "logs start line"
assert_grep "zones: cpu-0-0-0 gpuss-0$" "$T/log" "selects only cpu/gpu zones"

setup
settemp "$T" 0 97000
run_guard 40
assert_file "$T/returned" "97C for 30s: returns to One UI"
assert_file "$T/stage/thermal_tripped" "97C: leaves thermal_tripped marker"
assert_grep "TRIP: cpu-0-0-0 at 97C" "$T/log" "97C: logs trip reason"

setup
settemp "$T" 0 97000
run_guard 25
assert_no_file "$T/returned" "97C for only 25s: no trip yet"

setup
settemp "$T" 1 104000
run_guard 7
assert_file "$T/returned" "104C: emergency trip within 6s"

setup
settemp "$T" 0 200000
run_guard 40
assert_no_file "$T/returned" "bogus 200C sensor is ignored"

setup
echo 480 > "$T/batt_temp"
run_guard 61
assert_file "$T/returned" "battery 48C for 60s: trips"

setup
echo log > "$T/stage/thermal_guard"
settemp "$T" 0 99000
run_guard 40
assert_no_file "$T/returned" "log mode: never trips"
assert_grep "would trip" "$T/log" "log mode: logs the would-be trip"
assert_eq "$(cat "$T/cpufreq/policy0/scaling_max_freq")" 3000000 "log mode: never caps"

setup
settemp "$T" 0 88000
run_guard 22
assert_eq "$(cat "$T/cpufreq/policy0/scaling_max_freq")" 2000000 "88C for 20s: caps policy0 to 70% (nearest step)"
assert_eq "$(cat "$T/cpufreq/policy6/scaling_max_freq")" 2000000 "88C for 20s: caps policy6"
assert_file "$T/stage/thermal_cpufreq.saved" "cap saves original limits"
assert_no_file "$T/returned" "88C: soft stage does not exit Lineage"

# Same fake tree, now cool: the cap must lift after 60 s below 75 C. A new
# guard process starts uncapped (capped=0), so simulate the full sequence.
setup
cat > "$T/heat.sh" <<EOF
n=0
sleep() { n=\$((n + 1)); if [ \$n -ge 25 ]; then echo 50000 > "$T/thermal/thermal_zone0/temp"; fi; }
. "$GUARD"
EOF
settemp "$T" 0 88000
STAGE="$T/stage" TZ_ROOT="$T/thermal" BATT_TEMP="$T/batt_temp" \
CPUFREQ_ROOT="$T/cpufreq" THERMAL_LOG="$T/log" THERMAL_INTERVAL=1 \
THERMAL_MAX_ITER=100 GUARD_SH=sh "$TEST_SH" "$T/heat.sh" >/dev/null 2>&1
assert_eq "$(cat "$T/cpufreq/policy0/scaling_max_freq")" 3000000 "cooling for 60s lifts the cap"
assert_no_file "$T/stage/thermal_cpufreq.saved" "lifting the cap removes the save file"
assert_grep "lifting cap" "$T/log" "logs the cap lift"

setup
echo 0 > "$T/stage/thermal_softcap_pct"
settemp "$T" 0 90000
run_guard 30
assert_eq "$(cat "$T/cpufreq/policy0/scaling_max_freq")" 3000000 "thermal_softcap_pct=0 disables capping"

setup
echo 99 > "$T/stage/thermal_trip_c"
settemp "$T" 0 97000
run_guard 40
assert_no_file "$T/returned" "thermal_trip_c=99 raises the trip point"

finish
