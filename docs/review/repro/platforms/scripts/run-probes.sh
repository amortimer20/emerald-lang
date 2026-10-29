#!/bin/sh
# Runs every probe and benchmark with one emerald binary and writes each
# program's stdout, stderr and exit code under OUT. Run it on each platform,
# then compare the OUT directories with `diff -r`.
#   sh run-probes.sh EMERALD REPO_ROOT OUT
set -u
EM=$1; ROOT=$2; OUT=$3
P=$ROOT/docs/review/repro/platforms/probes
mkdir -p "$OUT"
WORK=$(mktemp -d)
cd "$WORK"
run() { # name, then the command
  name=$1; shift
  "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
  echo "exit $?" >>"$OUT/$name.out"
}
for f in floats math collections unicode files random; do
  run "$f" env -u TZ "$EM" run "$P/$f.em"
done
for tz in UTC America/New_York Europe/London Australia/Lord_Howe Asia/Kolkata EST5EDT "EST5EDT,M3.2.0,M11.1.0" ":America/New_York" "" Not/AZone "<+0530>-5:30"; do
  safe=$(printf '%s' "$tz" | tr '/:,<>+' '______')
  run "zones-TZ=$safe" env TZ="$tz" "$EM" run "$P/zones.em"
done
run "zones-TZunset" env -u TZ "$EM" run "$P/zones.em"
run program env EM_PROBE="Ünï ✓ 東京 👩‍👩‍👧" EM_EMPTY= "$EM" run "$P/program.em" -- "two words" "Ünïcödé" "" "e\\\"q" "東京 👍🏽" "-x" "--" "a=b"
for b in "$ROOT"/benchmarks/*.em; do
  n=$(basename "$b" .em)
  "$EM" run "$b" >"$OUT/bench-$n.out" 2>"$OUT/bench-$n.err"
  if cmp -s "$OUT/bench-$n.out" "$ROOT/benchmarks/$n.expected"; then echo "bench $n: matches"; else echo "bench $n: DIFFERS"; fi
done >"$OUT/benchmarks-summary.txt"
cd / && rm -rf "$WORK"
