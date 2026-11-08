#!/bin/sh
# Unit tests for the crash-loop guard embedded in switch_to_lineage.sh.
. "$(dirname "$0")/lib.sh"
echo "crashloop_guard"
GUARD=$(extract switch_to_lineage__CRASHLOOP)

setup() {
    T=$(tmpdir)
    STUBS="$T/bin"
    mkdir -p "$T/stage"
    # "busybox nsenter -t PID -m cmd..." -> record cmd, pretend success
    stub busybox 'shift 4; echo "$*" >> "'"$T"'/guest_calls"; exit 0'
    stub pidof 'echo 4242'
    # guest() compares mount namespaces: make system_server look different
    stub readlink 'case "$1" in /proc/self/*) echo "mnt:[1]" ;; *) echo "mnt:[2]" ;; esac'
}

# feed LINES...: run the guard once with a fake logcat printing the lines
feed() {
    printf '%s\n' "$@" > "$T/logcat.txt"
    stub logcat 'cat "'"$T"'/logcat.txt"'
    STAGE="$T/stage" CLG_LOG="$T/log" CLG_EVENTS="$T/events" BB="$STUBS/busybox" \
    CLG_ONCE=1 PATH="$STUBS:$PATH" "$TEST_SH" "$GUARD" >/dev/null 2>&1
}

crash() { echo "E/AndroidRuntime( 123): Process: $1, PID: 123"; }

setup
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)"
assert_no_file "$T/guest_calls" "4 crashes: below the limit, nothing disabled"

setup
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app:remote)"
assert_grep "pm disable-user --user 0 com.example.app$" "$T/guest_calls" "5 crashes (incl. :remote process): disabled in the guest"
assert_grep "am force-stop com.example.app" "$T/guest_calls" "disabled package is force-stopped"
assert_grep "^com.example.app$" "$T/stage/crashloop_disabled.txt" "recorded for crashloop-undo"

setup
feed "$(crash com.google.android.gms.persistent)" "$(crash com.google.android.gms.persistent)" \
     "$(crash com.google.android.gms)" "$(crash com.google.android.gms)" "$(crash com.google.android.gms)" \
     "$(crash com.google.android.gms)" "$(crash com.google.android.gms)"
assert_no_file "$T/guest_calls" "GMS is never disabled"
assert_grep "com.google.android.gms crashed .*core package" "$T/log" "GMS crash loop is logged"

setup
feed "$(crash com.android.systemui)" "$(crash com.android.systemui)" "$(crash com.android.systemui)" "$(crash com.android.systemui)" "$(crash com.android.systemui)"
assert_no_file "$T/guest_calls" "com.android.* is never disabled"

setup
echo com.example.app > "$T/stage/crashloop_allow"
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)"
assert_no_file "$T/guest_calls" "crashloop_allow protects a package"

setup
echo log > "$T/stage/crashloop_guard"
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)"
assert_no_file "$T/guest_calls" "log mode never disables"
assert_grep "would disable" "$T/log" "log mode logs what it would do"

setup
N="F/DEBUG   (  77): pid: 1234, tid: 1234, name: worker  >>> com.example.native <<<"
feed "$N" "$N" "$N" "$N" "$N"
assert_grep "pm disable-user --user 0 com.example.native$" "$T/guest_calls" "native crash loop (tombstone) detected"

setup
D="F/DEBUG   (  77): pid: 99, tid: 99, name: surfaceflinger  >>> /system/bin/surfaceflinger <<<"
feed "$D" "$D" "$D" "$D" "$D"
assert_no_file "$T/guest_calls" "native daemons (paths) are ignored"

setup
echo 3 > "$T/stage/crashloop_limit"
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)"
assert_grep "disable-user --user 0 com.example.app$" "$T/guest_calls" "crashloop_limit=3 is honoured"

setup
stub readlink 'echo "mnt:[1]"'
feed "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)" "$(crash com.example.app)"
assert_no_file "$T/guest_calls" "refuses to act when system_server shares our mount ns (One UI)"

setup
feed "E/AndroidRuntime( 1): java.lang.IllegalArgumentException: Unexpected safety source: AdvancedProtection"
assert_grep "GMS still hits SafetyCenter" "$T/log" "SafetyCenter crash is called out"

finish
