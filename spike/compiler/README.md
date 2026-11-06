# Compiler spike (slice 0, not for merge)

Hand-lowered `fib`, `nbody` and `words` from `benchmarks/`, in C (`*.c`) and in Zig (`*.zig`),
against a stub runtime (`rt.zig`, with `FloatMath.zig` copied from `src/`). `measure.py`
compiles both routes and times them against a ReleaseSafe interpreter in `../../out-rs`.
`board.c` and `hostlib.c` are the Pico and Godot questions. The report is in
`docs/compiler-design-plan.md` on main.

    zig build -Doptimize=ReleaseSafe --prefix out-rs          # from the repository root
    zig build-lib rt.zig -lc -OReleaseFast -femit-bin=out/emrt.lib
    python measure.py
