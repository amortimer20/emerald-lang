# Program

`Program` is a built-in namespace holding one constant about the running program itself. A
project that declares its own `Program` namespace keeps ownership of that name, and the
built-in one steps aside.

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
