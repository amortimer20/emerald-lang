#!/usr/bin/env bash
# Runs `emerald check` on every corpus program, and `emerald run` on those that check
# clean, and records the first diagnostic of each.
#
# Usage: docs/review/repro/errors/run.sh [path/to/emerald]
# Output: docs/review/repro/errors/results.txt  (every program's first diagnostic in full)
#         docs/review/repro/errors/results.tsv  (one row per program)
#
# results.tsv columns: program, expected line (from the header comment), stage (check or
# run), exit code, first diagnostic's line, auto place verdict, first diagnostic's message.
# The place verdict is "ok" when the first diagnostic is on the mistake's line or the line
# before it; the other three questions are judged by hand in docs/review/errors.md.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
emerald="${1:-$root/zig-out/bin/emerald}"
txt="$here/results.txt"
tsv="$here/results.tsv"
: > "$txt"
printf 'program\texpected\tstage\texit\tline\tplace\tmessage\n' > "$tsv"

# Timeout for `run`: an infinite loop in the corpus must not hang the runner.
to() { timeout "$@"; }
command -v timeout > /dev/null || to() { shift; "$@"; }

for f in "$here"/corpus/*.em; do
    name="$(basename "$f" .em)"
    expected="$(head -1 "$f" | sed -n 's/.*(line \([0-9]*\)).*/\1/p')"
    [ -n "$expected" ] || expected="-"
    out="$(cd "$here/corpus" && to 10 "$emerald" check "$name.em" 2>&1)"
    code=$?
    stage=check
    if [ $code -eq 0 ]; then
        stage=run
        out="$(cd "$here/corpus" && printf '21\n' | to 5 "$emerald" run "$name.em" 2>&1)"
        code=$?
        [ $code -eq 124 ] && out="$out
(timed out after 5 seconds: no diagnostic)"
    fi
    # The first diagnostic: from the first `file:line:col:` line up to the next one.
    first="$(printf '%s\n' "$out" | awk '
        /^[^ ].*\.em:[0-9]+:[0-9]+: / { n++ }
        n == 1 { print }
        n > 1 { exit }')"
    [ -n "$first" ] || first="$(printf '%s\n' "$out" | head -8)"
    line="$(printf '%s\n' "$first" | head -1 | sed -n 's/^[^ ]*\.em:\([0-9]*\):[0-9]*: .*/\1/p')"
    [ -n "$line" ] || line="-"
    msg="$(printf '%s\n' "$first" | head -1 | sed 's/^[^ ]*\.em:[0-9]*:[0-9]*: //')"
    place="-"
    if [ "$line" != "-" ] && [ "$expected" != "-" ]; then
        if [ "$line" -eq "$expected" ] || [ "$line" -eq $((expected - 1)) ]; then
            place=ok
        else
            place=off
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$expected" "$stage" "$code" "$line" "$place" "$msg" >> "$tsv"
    {
        printf '=== %s (mistake on line %s; %s exit %s)\n' "$name" "$expected" "$stage" "$code"
        printf '%s\n\n' "$first"
    } >> "$txt"
done
echo "wrote $tsv and $txt"
