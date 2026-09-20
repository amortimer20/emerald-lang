# Errors, tests, and projects

Emerald's error-handling and testing *mechanics* — `Error`/`RuntimeError`/`AssertionError`,
`raise`/`catch`/`finally`, `assert`, and `@test`/`emerald test` — are documented in full on
the [Errors and tests](../library/errors.md) library page, since they read more like an API
surface than syntax to learn gradually. This guide covers what that page doesn't: how a
program grows from one file into several, and how errors and tests interact with that
structure.

## One file, or a project

A single `.em` file is already a complete program. A directory becomes a **project** only
once it holds `main.em`; running a file that isn't part of one still just runs that file
alone, which is what lets a folder of independent exercises work the way a beginner expects
— `emerald run ex1.em` never sees `ex2.em` beside it, even if both declare `func helper`.
Only the directory a file sits in is ever consulted for this, never a directory above it, so
a file inside some other project's subdirectory, run on its own, is a program on its own too.

Inside a project, **every** `.em` file under the project root is included automatically —
there's nothing to import and no file list to maintain. `main.em` is the entry file: only its
top-level statements run. Every other file may declare functions, types, and module-level
bindings, but not run arbitrary top-level code — a module-level binding with no value is
rejected right where it's written, since there's nowhere else for it to be assigned, and a
bare executable statement outside a function in a non-entry file is rejected too:

```emerald
# helpers/greet.em
print("this runs at load time")   # error: this would never run

func greet(): String {
    return "hi"
}
```

See [`examples/project/main.em`](../../examples/project/main.em) (which pulls in
`scoring/scores.em` and `scoring/grades.em` beside it) for a small multi-file project end to
end, and [`examples/ledger/main.em`](../../examples/ledger/main.em) for a persisted
command-line project using `Program.arguments`, `File`, `Directory`, and `Path`,
and
[`conformance/diagnostics/module-statement`](../../conformance/diagnostics/module-statement)
and
[`conformance/diagnostics/module-needs-value`](../../conformance/diagnostics/module-needs-value)
for the two rejections above with their exact wording.

## Ending the program early, and reading its arguments

Only the entry file's top level may use a bare `return` — nowhere else outside a function.
It ends the program successfully right where it runs, after any pending `finally` blocks
finish their cleanup, and it cannot return a value:

```emerald
print("starting")
if some_condition {
    return
}
print("only reached when some_condition is false")
```

Use `exit(code)` (see [Prelude](../library/prelude.md)) instead when the program needs to
choose its own status. Code written after an *unconditional* top-level `return` warns the
same way code after `raise` or an unconditional `break` does — the checker only knows a
conditional one like the example above might not run.

`Program.arguments` is a `List[String]` of the program's own command-line arguments — a
project's, not Emerald's own — read from whatever follows `--`:

```text
emerald run greet.em -- Ava
```

excluding the `emerald` executable and the entry file's own path. Each read is a fresh,
independent `List`, and it is always `[]` outside `emerald run`/`emerald test` — under
`emerald check`, the REPL, or the LSP, there is no invocation to take it from. See
[`Program`](../library/program.md) for the full page.

## Namespaces and `using`

Directories form namespaces; the file inside contributes nothing to the name. A directory
becomes one namespace segment, written the way a type is: `game/shapes/circle.em` puts its
declarations in `Shapes`, and moving that declaration into a sibling file in the same
directory changes nothing any other file writes.

```emerald
# main.em
using Scoring

print(Scoring.grade(90))
print(grade(90))   # the same thing, once `using Scoring` is in effect
```

`using` is file-local — it applies to the whole file it's written in, regardless of where in
the file it appears — imports only public names, and never includes or runs a file by
itself; project inclusion is independent of it. An alias resolves a collision explicitly:
`using Short = Graphics.Color`. Reaching a namespace's name directly, without `using` or
qualification, is rejected (`` `area` is not visible here ``); reaching the namespace itself
as though it were a value is rejected too (`` `Shapes` is a namespace, not a value ``); and a
name two active `using` declarations both offer is an ambiguity naming both, resolved by
qualifying it or giving one an alias. See
[`conformance/diagnostics/name-needs-its-namespace`](../../conformance/diagnostics/name-needs-its-namespace),
[`conformance/diagnostics/namespace-not-a-value`](../../conformance/diagnostics/namespace-not-a-value),
and
[`conformance/diagnostics/ambiguous-using`](../../conformance/diagnostics/ambiguous-using).

Same-directory names are directly visible to each other with no qualification at all, in
whatever order the files happen to be read — `grades.em` can call `pass_mark` straight from
`scores.em` beside it, since both sit in the same namespace. Two files in one directory
declaring the same public name is rejected, naming the earlier file:
[`conformance/diagnostics/duplicate-in-namespace`](../../conformance/diagnostics/duplicate-in-namespace).
A leading underscore keeps a module-level declaration private to the file that declares it —
not just the directory — so two files may each have their own private `_helper` with no
collision, and neither can reach the other's:
[`conformance/diagnostics/private-across-files`](../../conformance/diagnostics/private-across-files).

## Lazy, once-only initialization

A non-entry file initializes the first time anything in it is used — never merely by being
included in the project, or named in a `using` — and its bindings run once, in declaration
order, the same lazy rule a type's type-level fields follow. Reaching a function from a file
that hasn't finished initializing yet is fine, since the function's body doesn't run until
it's called, but reaching one of that file's *bindings* before initialization gets to it is
an initialization-cycle error — the diagnostic below is what two files waiting on each
other's values looks like:

```emerald
# first/one.em
const value = Second.value
# second/two.em
const value = First.value
```

```text
`second/two.em` is still being set up, so `First.value` cannot be read yet
```

Break a cycle like this by moving one side into a function, which runs when called rather
than when the file is set up. See
[`conformance/runtime-errors/initialization-cycle`](../../conformance/runtime-errors/initialization-cycle)
and
[`conformance/run/lazy-module-list-mutation`](../../conformance/run/lazy-module-list-mutation)
for the ordinary, non-cyclic case: a module-level `var` mutated straight from another file
through `using`, no different from a value the entry file declared itself.

## Errors and tests inside a project

Nothing about `raise`/`catch`/`finally` or `Error` changes across file boundaries — an error
class declared in one file is an ordinary declaration like any other, reached by namespace or
`using` like any other. `@test` is where projects matter more directly: `emerald test`
discovers `@test` functions across every file in the project, not only the entry file, and
runs the whole project in **test mode** — the entry file's top-level statements are skipped
entirely, while its bindings still initialize lazily under the same rule as any other file,
the first time a test actually reaches one. That's what lets a test suite reuse an entry
file's declarations without ever starting the program those statements describe, while still
observing whatever a test deliberately triggers. See [Errors and tests](../library/errors.md)
for `@test`'s own rules (no parameters, no result, deterministic order, exit `3` on failure)
and every `raise`/`catch`/`finally` mechanic this guide doesn't repeat.
