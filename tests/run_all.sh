#!/bin/sh
# Runs every offline check for the device scripts. Used by CI
# (.github/workflows/scripts.yml) and runnable locally:
#   sh tests/run_all.sh
# Needs: mksh (Android's /system/bin/sh), busybox, dash, shellcheck, file.
# Missing tools are reported and skipped locally, but CI installs all of them.
# Nothing here touches a phone: these checks prove syntax, line endings and the
# decision logic of the watchdogs against fake sysfs trees, NOT device behaviour.
set -u
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)
STATUS=0
bad() { echo "FAIL: $*"; STATUS=1; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "== line endings =="
for f in assets/*.sh assets/*.xml assets/preloaded-classes tests/*.sh; do
    if grep -q "$(printf '\r')" "$f"; then bad "$f has CRLF line endings"; fi
done
echo "ok"

echo "== binaries =="
if [ "$(head -c 4 assets/zygote_exec | od -An -c | tr -d ' \n')" != '177ELF' ]; then
    bad "assets/zygote_exec is not an ELF file any more"
fi
if have file && ! file assets/zygote_exec | grep -q 'ARM aarch64'; then
    bad "assets/zygote_exec is not an aarch64 ELF"
fi
if have git && git rev-parse --git-dir >/dev/null 2>&1; then
    for f in assets/zygote_exec assets/framework_patched.jar assets/services_patched.jar assets/7zz; do
        attr=$(git check-attr text -- "$f" | awk '{print $NF}')
        [ "$attr" = "unset" ] || bad "$f must be marked binary in .gitattributes (text: $attr)"
    done
fi
echo "ok"

echo "== shebangs =="
for f in assets/*.sh; do
    head -n 1 "$f" | grep -q '^#!/system/bin/sh' || bad "$f does not start with #!/system/bin/sh"
done
echo "ok"

HD=$(mktemp -d "${TMPDIR:-/tmp}/ol17hd.XXXXXX")
sh tests/extract_heredocs.sh "$HD" assets/*.sh > "$HD/.list" || bad "heredoc extraction failed"
echo "== syntax ($(wc -l < "$HD/.list") embedded scripts + $(ls assets/*.sh | wc -l) top-level) =="
for f in assets/*.sh "$HD"/*.sh; do
    for sh in mksh dash busybox; do
        have "$sh" || continue
        if [ "$sh" = busybox ]; then out=$(busybox sh -n "$f" 2>&1); else out=$("$sh" -n "$f" 2>&1); fi
        [ $? -eq 0 ] || bad "[$sh -n] $(basename "$f"): $out"
    done
done
have mksh || echo "WARNING: mksh missing, Android's shell was not checked"
echo "ok"

echo "== shellcheck (errors only) =="
if have shellcheck; then
    shellcheck -s ksh -S error assets/*.sh "$HD"/*.sh || bad "shellcheck reported errors"
    echo "ok"
else
    echo "skipped: shellcheck not installed"
fi

echo "== private data scan =="
# The repo is public. Device scripts must never carry serials, Wi-Fi names,
# credentials or key material.
if have git; then
    hits=$(git ls-files -z | xargs -0 grep -I -n -i -E \
        'BEGIN [A-Z ]*PRIVATE KEY|ro\.serialno=[A-Za-z0-9]|password *= *[^ ]|passwd *= *[^ ]|api[_-]?key *= *[A-Za-z0-9]|wpa_passphrase|psk="|ssid="' \
        -- 2>/dev/null | grep -v '^tests/run_all.sh:' || true)
    [ -z "$hits" ] || bad "possible private data:
$hits"
fi
echo "ok"

echo "== unit tests =="
for sh in ${TEST_SHELLS:-mksh busybox dash}; do
    if [ "$sh" = busybox ]; then have busybox || continue; else have "$sh" || continue; fi
    for t in tests/test_*.sh; do
        [ -f "$t" ] || continue
        echo "-- $t under $sh"
        TEST_SH=$sh sh "$t" || bad "$t failed under $sh"
    done
done

rm -rf "$HD"
echo
if [ $STATUS -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit $STATUS
