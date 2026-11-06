"""Measures the compiler spike: compile time (cold and warm cache), run time
(median of 5) against the interpreter, and binary size, for both routes.

Run from spike/compiler after building out/emrt.lib and ../../out-rs (a
ReleaseSafe interpreter). Not for merge."""
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
OUT = os.path.join(HERE, 'out')
EXE = '.exe' if os.name == 'nt' else ''
LIB = os.path.join(OUT, 'emrt.lib' if os.name == 'nt' else 'libemrt.a')
EMERALD = os.path.join(ROOT, 'out-rs', 'bin', 'emerald' + EXE)
PROGRAMS = ['fib', 'nbody', 'words']


def timed(cmd, env=None):
    start = time.perf_counter()
    result = subprocess.run(cmd, cwd=HERE, env=env, capture_output=True, text=True)
    elapsed = time.perf_counter() - start
    if result.returncode != 0:
        sys.exit(f'failed: {" ".join(cmd)}\n{result.stdout}{result.stderr}')
    return elapsed, result.stdout


def compile_cmd(route, program, target):
    if route == 'c':
        return ['zig', 'cc', '-O2', '-o', target, program + '.c', LIB]
    return ['zig', 'build-exe', program + '.zig', '-lc', '-OReleaseFast', '-femit-bin=' + target]


def compile_times(route, program):
    target = os.path.join(OUT, f'{program}_{route}{EXE}')
    cold_dir = tempfile.mkdtemp(prefix='zigcache-')
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=cold_dir, ZIG_LOCAL_CACHE_DIR=cold_dir)
    cold, _ = timed(compile_cmd(route, program, target), env)
    shutil.rmtree(cold_dir, ignore_errors=True)
    # Warm: the cache holds libc and the runtime but not this program's code,
    # so touch the source to force its recompilation.
    timed(compile_cmd(route, program, target))
    os.utime(os.path.join(HERE, program + ('.c' if route == 'c' else '.zig')))
    warm, _ = timed(compile_cmd(route, program, target))
    return cold, warm, target


def run_median(cmd):
    times = []
    output = None
    for _ in range(5):
        elapsed, output = timed(cmd)
        times.append(elapsed)
    return statistics.median(times), output.strip()


def main():
    rows = []
    for program in PROGRAMS:
        expected = open(os.path.join(ROOT, 'benchmarks', program + '.expected')).read().strip()
        interp, out = run_median([EMERALD, 'run', os.path.join(ROOT, 'benchmarks', program + '.em')])
        assert out == expected, (program, 'interpreter', out)
        row = {'program': program, 'interpreter': interp}
        for route in ('c', 'zig'):
            cold, warm, target = compile_times(route, program)
            run, out = run_median([target])
            assert out == expected, (program, route, out)
            row[route] = (cold, warm, run, os.path.getsize(target))
        rows.append(row)

    print('| Program | Interpreter | C run | Zig run | C speed-up | Zig speed-up |')
    print('| --- | --- | --- | --- | --- | --- |')
    for r in rows:
        print(f"| `{r['program']}` | {r['interpreter']:.3f}s | {r['c'][2]:.3f}s | {r['zig'][2]:.3f}s | "
              f"{r['interpreter'] / r['c'][2]:.1f}x | {r['interpreter'] / r['zig'][2]:.1f}x |")
    print()
    print('| Program | C compile cold | C compile warm | Zig compile cold | Zig compile warm | C size | Zig size |')
    print('| --- | --- | --- | --- | --- | --- | --- |')
    for r in rows:
        print(f"| `{r['program']}` | {r['c'][0]:.1f}s | {r['c'][1]:.2f}s | {r['zig'][0]:.1f}s | {r['zig'][1]:.2f}s | "
              f"{r['c'][3] / 1024:.0f} KB | {r['zig'][3] / 1024:.0f} KB |")


main()
