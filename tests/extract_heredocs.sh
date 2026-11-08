#!/bin/sh
# Extract every script that the device scripts generate with
#   cat > /some/path <<'TAG'
#   ...
#   TAG
# into OUT_DIR/<source>__<TAG>.sh so CI can syntax-check and unit-test them.
# Several earlier boot failures were syntax errors inside these embedded
# scripts (ui_activator), which `sh -n` on the outer file cannot catch because
# a quoted heredoc is just data to the outer shell.
#
# usage: tests/extract_heredocs.sh OUT_DIR file.sh [file.sh ...]
set -eu
out=$1
shift
mkdir -p "$out"
for src in "$@"; do
    base=$(basename "$src" .sh)
    awk -v out="$out" -v base="$base" '
        tag == "" && /cat[ \t]+>.*<<[ \t]*'\''?[A-Za-z_][A-Za-z0-9_]*'\''?[ \t]*$/ {
            t = $0
            sub(/.*<<[ \t]*/, "", t)
            gsub(/'\''/, "", t)
            gsub(/[ \t]/, "", t)
            tag = t
            file = out "/" base "__" tag ".sh"
            printf "" > file
            next
        }
        tag != "" && $0 == tag { close(file); print file; tag = ""; next }
        tag != "" { print >> file }
        END { if (tag != "") { print "unterminated heredoc " tag " in " base > "/dev/stderr"; exit 1 } }
    ' "$src"
done
