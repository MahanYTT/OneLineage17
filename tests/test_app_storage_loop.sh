#!/bin/sh
# Unit tests for the app storage sweeper loop embedded in master_prepare.sh.
. "$(dirname "$0")/lib.sh"
echo "app_storage_loop"
LOOP_SRC=$(extract master_prepare__APPLOOP)

setup() {
    T=$(tmpdir)
    STUBS="$T/bin"
    mkdir -p "$T/flags"
    stub getprop 'echo 1'
    stub am 'echo "am $*" >> "'"$T"'/am_calls"'
    echo "com.example.app 10123 0" > "$T/packages.list"
    printf '#!/bin/sh\necho x >> "%s/sweeps"\n' "$T" > "$T/ensure.sh"
    printf '#!/bin/sh\n' > "$T/net.sh"
    # The loop calls /system/bin/sh, which CI does not have.
    sed 's#/system/bin/sh #sh #g' "$LOOP_SRC" > "$T/loop.sh"
}

run_loop() { # run_loop ITERATIONS SLEEP_FUNCTION_DEFINITION
    LINEAGE_FLAGS="$T/flags" ENSURE_APP_STORAGE="$T/ensure.sh" NET_FIX="$T/net.sh" \
    PACKAGES_LIST="$T/packages.list" APP_STORAGE_LOG="$T/app.log" APP_LOOP_SLEEP=0 \
    APP_LOOP_MAX="$1" PATH="$STUBS:$PATH" \
    "$TEST_SH" -c "$2 . \"\$0\"" "$T/loop.sh" >/dev/null 2>&1
}
sweeps() { if [ -f "$T/sweeps" ]; then wc -l < "$T/sweeps" | tr -d ' '; else echo 0; fi; }

setup
run_loop 35 'sleep() { :; };'
assert_eq "$(sweeps)" 2 "35 loops, packages.list unchanged: 2 sweeps (start + 5-min safety net), not 35"

setup
run_loop 10 'n_=0; sleep() { n_=$((n_ + 1)); [ $n_ -eq 5 ] && echo "com.new.app 10200 0" >> "'"$T"'/packages.list"; :; };'
assert_eq "$(sweeps)" 2 "an install (packages.list change) triggers a sweep"
assert_grep "am force-stop com.android.launcher3" "$T/am_calls" "an install refreshes the launcher"

setup
echo 1 > "$T/flags/storage_sweep_full"
run_loop 12 'sleep() { :; };'
assert_eq "$(sweeps)" 12 "storage_sweep_full=1 restores the old every-loop sweep"

finish
