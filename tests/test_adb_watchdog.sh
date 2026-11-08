#!/bin/sh
# Unit tests for the adb watchdog embedded in switch_to_lineage.sh.
. "$(dirname "$0")/lib.sh"
echo "adb_watchdog"
ADBW=$(extract switch_to_lineage__ADBW)

setup() {
    T=$(tmpdir)
    STUBS="$T/bin"
    mkdir -p "$T/stage" "$T/props"
    stub getprop 'cat "'"$T"'/props/$1" 2>/dev/null'
    stub setprop 'printf "%s" "$2" > "'"$T"'/props/$1"; echo "$1=$2" >> "'"$T"'/setprop_calls"'
    printf running > "$T/props/init.svc.adbd"
    printf 'sec_charging,adb' > "$T/props/sys.usb.state"
}
setp() { printf '%s' "$2" > "$T/props/$1"; }
run() { STAGE="$T/stage" ADBW_LOG="$T/log" ADBW_MAX_ITER="$1" PATH="$STUBS:$PATH" "$TEST_SH" -c 'sleep() { :; }; . "$0"' "$ADBW" >/dev/null 2>&1; }

setup
setp sys.usb.config 'sec_charging,adb'
run 3
assert_no_file "$T/setprop_calls" "healthy config: nothing rewritten"

setup
setp sys.usb.config adb
run 1
assert_eq "$(cat "$T/props/sys.usb.config")" "sec_charging,adb" "bare adb -> sec_charging,adb"

setup
setp sys.usb.config mtp
run 1
assert_eq "$(cat "$T/props/sys.usb.config")" "mtp,adb" "adb added to another function"

setup
setp sys.usb.config 'sec_charging,adb'
setp init.svc.adbd stopped
run 1
assert_grep "ctl.start=adbd" "$T/setprop_calls" "dead adbd is restarted"

setup
setp sys.usb.config 'sec_charging,adb'
run 1
assert_grep "usb.state: '' -> 'sec_charging,adb'" "$T/log" "usb.state changes are logged"

setup
setp sys.usb.config 'sec_charging,adb'
echo 5555 > "$T/stage/adb_tcp"
run 2
assert_eq "$(cat "$T/props/service.adb.tcp.port")" 5555 "adb_tcp: tcp port re-asserted"
assert_eq "$(grep -c 'ctl.restart=adbd' "$T/setprop_calls")" 1 "adb_tcp: adbd restarted only once"

setup
setp sys.usb.config 'sec_charging,adb'
run 2
assert_no_grep "service.adb.tcp.port" "$T/setprop_calls" "no adb_tcp file: tcp stays off"

finish
