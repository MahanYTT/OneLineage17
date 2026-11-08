#!/bin/sh
# Tiny assertion helpers shared by tests/test_*.sh. POSIX sh only.
# Every test runs the device scripts with an alternative shell ($TEST_SH,
# default mksh, which is what /system/bin/sh is on Android) against a fake
# filesystem in a temp dir. Device-only commands are stubbed via $STUBS on PATH.

TEST_SH=${TEST_SH:-mksh}
if [ "$TEST_SH" = busybox ]; then
    # busybox needs "busybox sh"; wrap it so "$TEST_SH" stays one word.
    _bb=$(mktemp "${TMPDIR:-/tmp}/bbsh.XXXXXX")
    printf '#!/bin/sh\nexec busybox sh "$@"\n' > "$_bb"
    chmod +x "$_bb"
    TEST_SH=$_bb
fi
command -v "$TEST_SH" >/dev/null 2>&1 || TEST_SH=sh
REPO=$(cd "$(dirname "$0")/.." && pwd)
FAILS=0
PASSES=0

tmpdir() {
    d=$(mktemp -d "${TMPDIR:-/tmp}/ol17test.XXXXXX")
    echo "$d"
}

pass() { PASSES=$((PASSES + 1)); echo "  ok   - $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

assert_file() { if [ -e "$1" ]; then pass "$2"; else fail "$2" "missing: $1"; fi; }
assert_no_file() { if [ ! -e "$1" ]; then pass "$2"; else fail "$2" "unexpected: $1"; fi; }
assert_eq() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi; }
assert_grep() { if grep -qE -- "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3" "no /$1/ in $2: $(tail -n 5 "$2" 2>/dev/null | tr '\n' '|')"; fi; }
assert_no_grep() { if ! grep -qE -- "$1" "$2" 2>/dev/null; then pass "$3"; else fail "$3" "found /$1/ in $2"; fi; }

# extract NAME: print the path of the heredoc script NAME (e.g.
# switch_to_lineage__THERMAL) extracted from the assets into $HD.
HD=""
extract() {
    if [ -z "$HD" ]; then
        HD=$(tmpdir)
        sh "$REPO/tests/extract_heredocs.sh" "$HD" "$REPO"/assets/*.sh >/dev/null
    fi
    f="$HD/$1.sh"
    [ -f "$f" ] || { echo "no extracted script $1" >&2; exit 2; }
    echo "$f"
}

# stub NAME BODY: create an executable stub command in $STUBS.
stub() {
    mkdir -p "$STUBS"
    printf '#!/bin/sh\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}

finish() {
    echo "  $PASSES passed, $FAILS failed"
    [ "$FAILS" -eq 0 ]
}
