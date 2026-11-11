#!/bin/sh
# Unit tests for lineage_ctl.sh (embedded in switch_to_lineage.sh).
. "$(dirname "$0")/lib.sh"
echo "lineage_ctl"
CTL=$(extract switch_to_lineage__CTL)

T=$(tmpdir)
STUBS="$T/bin"
mkdir -p "$T/stage/data/local/tmp/lineage_flags" "$T/thermal/thermal_zone0" "$T/thermal/thermal_zone1"
echo cpu-1-0 > "$T/thermal/thermal_zone0/type"; echo 71000 > "$T/thermal/thermal_zone0/temp"
echo gpuss-0 > "$T/thermal/thermal_zone1/type"; echo 64000 > "$T/thermal/thermal_zone1/temp"
stub pidof 'exit 1'
ctl() { STAGE="$T/stage" TZ_ROOT="$T/thermal" BB=busybox PATH="$STUBS:$PATH" "$TEST_SH" "$CTL" "$@" > "$T/out" 2>&1; }

ctl temps
assert_eq "$(head -n 1 "$T/out")" "71 cpu-1-0" "temps: hottest zone first, in C"

ctl set thermal_trip_c 97
assert_eq "$(cat "$T/stage/thermal_trip_c")" 97 "set writes the host flag"
assert_eq "$(cat "$T/stage/data/local/tmp/lineage_flags/thermal_trip_c")" 97 "set mirrors the flag into the guest"

ctl flags
assert_grep "thermal_trip_c +97 +\(default 95\)" "$T/out" "flags shows value and default"
assert_grep "thermal_zones +- +\(default \(cpu/gpu/nsp...\)\)" "$T/out" "flags table parses every row"
n=$(grep -c '(default' "$T/out")
assert_eq "$n" 40 "flags lists all 40 toggles"

ctl unset thermal_trip_c
assert_no_file "$T/stage/thermal_trip_c" "unset removes the flag"

ctl density 500
assert_eq "$(cat "$T/stage/density")" 500 "density is persisted even when Lineage is down"
assert_grep "not running" "$T/out" "density reports when Lineage is down"

ctl help
assert_grep "usage: lineage_ctl.sh" "$T/out" "help prints usage"

finish
