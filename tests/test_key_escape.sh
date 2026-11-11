#!/bin/sh
# Unit tests for the volume-key escape embedded in switch_to_lineage.sh.
# A fake getevent replays key events with real short pauses; HOLD is 1 s
# unless a test removes key_escape_secs (default: no hold).
. "$(dirname "$0")/lib.sh"
echo "key_escape"
KE=$(extract switch_to_lineage__KEYESC)

setup() {
    T=$(tmpdir)
    mkdir -p "$T/stage"
    echo 1 > "$T/stage/key_escape_secs"
    printf '#!/bin/sh\necho returned > "%s/returned"\n' "$T" > "$T/stage/return_to_oneui.sh"
}
# replay FILE: each line is either "sleep N" or an event "KEY STATE"
replay() {
    cat > "$T/fake_getevent" <<EOF
#!/bin/sh
while read -r a b; do
    case "\$a" in
        sleep) sleep "\$b" ;;
        *) echo "/dev/input/event0: EV_KEY       \$a       \$b" ;;
    esac
done < "$1"
EOF
    chmod 755 "$T/fake_getevent"
    STAGE="$T/stage" KEYESC_LOG="$T/log" KEYESC_STATE="$T/both" \
    GETEVENT="$T/fake_getevent" KEYESC_SH=sh "$TEST_SH" "$KE" >/dev/null 2>&1
    sleep 2   # let the hold timer and the detached return script finish
}

setup
cat > "$T/ev" <<EOF
KEY_VOLUMEUP DOWN
KEY_VOLUMEDOWN DOWN
sleep 1.6
KEY_VOLUMEUP UP
KEY_VOLUMEDOWN UP
EOF
replay "$T/ev"
assert_file "$T/returned" "both keys held past the hold time: returns to One UI"
assert_grep "returning to One UI" "$T/log" "logs the escape"

setup
cat > "$T/ev" <<EOF
KEY_VOLUMEUP DOWN
KEY_VOLUMEDOWN DOWN
sleep 0.3
KEY_VOLUMEDOWN UP
sleep 1.5
KEY_VOLUMEUP UP
EOF
replay "$T/ev"
assert_no_file "$T/returned" "short press of both keys: nothing happens"

setup
cat > "$T/ev" <<EOF
KEY_VOLUMEUP DOWN
sleep 1.6
KEY_VOLUMEUP UP
KEY_VOLUMEDOWN DOWN
sleep 1.6
KEY_VOLUMEDOWN UP
EOF
replay "$T/ev"
assert_no_file "$T/returned" "one key at a time, even held long: nothing happens"

setup
cat > "$T/ev" <<EOF
KEY_POWER DOWN
KEY_VOLUMEDOWN DOWN
sleep 1.6
KEY_VOLUMEDOWN UP
KEY_POWER UP
EOF
replay "$T/ev"
assert_no_file "$T/returned" "power + volume down (screenshot): nothing happens"

setup
rm -f "$T/stage/key_escape_secs"
cat > "$T/ev" <<EOF
KEY_VOLUMEUP DOWN
KEY_VOLUMEDOWN DOWN
sleep 0.2
KEY_VOLUMEDOWN UP
KEY_VOLUMEUP UP
EOF
replay "$T/ev"
assert_file "$T/returned" "default: a short press of both keys returns to One UI"
assert_grep "both volume keys pressed" "$T/log" "default: logs the press"

setup
rm -f "$T/stage/key_escape_secs"
cat > "$T/ev" <<EOF
KEY_VOLUMEUP DOWN
KEY_VOLUMEUP UP
KEY_VOLUMEDOWN DOWN
KEY_VOLUMEDOWN UP
KEY_VOLUMEUP DOWN
KEY_VOLUMEUP UP
EOF
replay "$T/ev"
assert_no_file "$T/returned" "default: separate presses do nothing"

finish
