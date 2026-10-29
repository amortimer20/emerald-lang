#!/bin/sh
# Re-run the area-4 (tasks and cancellation) sweep. Run from the repository root.
#   docs/review/repro/tasks/run-all.sh RELEASESAFE_EMERALD DEBUG_EMERALD
# Results print to standard output; see docs/review/tasks.md for what was found.
set -u
RS=$1
DBG=$2
HERE=docs/review/repro/tasks

# Every task/channel program in conformance/run, conformance/runtime-errors,
# examples, and tools, except those that need a live pipe or write fixed files.
ALL=$(grep -lE "Tasks|Channel" conformance/run/*.em conformance/runtime-errors/*.em examples/*.em tools/task-*.em |
    grep -v -e task-cancel-input-live -e task-file- -e task-io-order)
SERIAL="conformance/run/task-file-operations.em conformance/run/task-file-stream.em tools/task-io-order-probe.em"

python3 $HERE/stress.py "$RS" 1000 8 $ALL
python3 $HERE/stress.py "$RS" 1000 1 $SERIAL
python3 $HERE/stress.py "$DBG" 200 6 $ALL
python3 $HERE/stress.py "$DBG" 200 1 $SERIAL

EDGE=$(ls $HERE/edge/e*.em | grep -v -e e32- -e e33- -e e34- -e e43- -e e45-)
python3 $HERE/stress.py "$RS" 1000 8 $EDGE
python3 $HERE/stress.py "$DBG" 200 8 $EDGE
STRESS_TIMEOUT=120 python3 $HERE/stress.py "$RS" 50 8 $HERE/edge/e45-throughput.em

# Held-open standard input.
for B in "$RS 1000" "$DBG 200"; do
    set -- $B
    python3 $HERE/stdin_stress.py $1 $2 8 conformance/run/task-cancel-input-live.em 0.2 measured -- x
    python3 $HERE/stdin_stress.py $1 $2 8 $HERE/edge/e32-exit-while-input-blocked.em 30 never
    python3 $HERE/stdin_stress.py $1 $2 8 $HERE/edge/e33-cancel-input-then-read.em 0.2 late
    python3 $HERE/stdin_stress.py $1 $2 8 $HERE/edge/e34-two-input-readers.em 0.2 one two
    python3 $HERE/stdin_stress.py $1 $2 8 $HERE/edge/e43-exit-in-child-main-on-input.em 30 never
done

# One reduced reproduction per finding (status shown after each).
for f in $HERE/f*.em; do
    echo "=== $f"
    "$RS" run "$f" </dev/null
    echo "[exit $?]"
done
