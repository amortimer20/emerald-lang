# Program

`Program` is a built-in namespace about the running program itself: its arguments, and a way
to pause it. A project that declares its own `Program` namespace keeps ownership of that
name, and the built-in one steps aside.

Run [`conformance/run/program-arguments.em`](../../conformance/run/program-arguments.em) for
the default (empty) case; the CLI examples below show how a program actually receives some.

## Program.arguments -> List[String]

The program's own arguments: whatever follows `--` on the command line, excluding the
`emerald` executable and the entry file's own path.

```text
emerald run greet.em -- Ava
emerald test suite.em -- --seed 42
```

Reads a fresh, independent `List` each time — mutating one read never affects another, the
same as any other value. Outside `emerald run`/`emerald test` (under `emerald check`, the
REPL, or the LSP) it is always `[]`, since there is no program invocation to take it from.

`Program.arguments()` is a checking-time error: it is a constant, not a method, and takes no
parentheses.

## Program.sleep(duration: Duration) -> Nothing

Pauses the program for `duration`, then carries on. It blocks: nothing else in the program
runs meanwhile, which suits a countdown or a simple animation. See
[`conformance/run/clock.em`](../../conformance/run/clock.em).

```emerald
for count in 3.down_to(1) {
    print(count)
    Program.sleep(Duration(seconds: 1))
}
print("Go!")
```

The argument is always a `Duration`, so its unit is never in doubt: `Program.sleep(1)` is a
checking-time error that suggests `Duration(seconds: 1)`. A zero `Duration` returns at once.

**Raises** `DateTimeError` for a negative `Duration`.
