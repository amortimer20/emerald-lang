# Errors and tests

Errors are ordinary typed values rooted in the prelude's `Error` class, not a distinct
control-flow type. `raise`, `catch`, and `finally` are language statements rather than
methods, and `assert`/`@test` are how Emerald programs check themselves — this page covers
all of them together, matching how [`docs/library/inventory.md`](inventory.md) groups them.
Run [`conformance/run/errors.em`](../../conformance/run/errors.em) for most cases below and
[`conformance/diagnostics/error-checking.em`](../../conformance/diagnostics/error-checking.em)
for every checking-time mistake's exact text.

## The Error hierarchy

```emerald
class InvalidScore extends Error {
}

raise InvalidScore("Score cannot be negative")
```

`Error` stores one read-only `message: String`. A subclass whose only stored state is that
inherited message — like `InvalidScore` above — gets the compact one-argument
`Error(message)` construction for free; a subclass that adds its own fields declares an
ordinary constructor starting with `super(message)`, like any other class (10.7), and a
subclass that adds required state but no constructor is a checking error (`needs a
constructor, because building {base} takes arguments`).

Four subclasses are built in: **`RuntimeError`**, raised by interpreter-detected failures
(overflow, division by zero, an out-of-range index, and every other **Raises** case
documented on the other library pages), and **`AssertionError`**, raised by a failed
`assert`. Both are ordinary `Error` subclasses a typed or untyped `catch` can handle like any
other. **`FileError`** extends `RuntimeError` and is raised by the whole-file filesystem
operations, so `catch error: FileError` handles missing paths and access failures without
also handling unrelated runtime failures. **`DateTimeError`** extends `RuntimeError` too, and
is raised by [dates and times](dates-and-times.md) for a value that cannot exist, text in the
wrong form, or an unknown time zone.

`raise` accepts only an `Error` value.

**Raises** nothing here — `raise 1` is a checking-time error
(`` only an Error can be raised, but this is Int ``), not a runtime one.

## try / catch / finally

```emerald
try {
    load_game()
}
catch error: FileError {
    print(error.message)
}
finally {
    print("Finished loading")
}
```

Typed `catch` clauses are tried top to bottom; the first whose type matches the raised
value's class (or a class it extends) runs. An untyped `catch error { ... }` handles any
`Error` and must be the last clause — one written before a later `catch` is a checking-time
error on the untyped clause itself (`` this catch already handles every Error ``, with help
to move it after the typed catches). `finally` runs whether the protected body returns,
raises, or completes normally, and `try` may have `finally` with no `catch` at all.

Bare `raise` inside a `catch` block re-raises the same value with its original failure
location; writing it anywhere else is a checking-time error
(`` a bare `raise` needs an error being handled ``).

`return`, `break`, and `continue` may not leave a `finally` block — cleanup cannot replace a
result or suppress an error this way (a loop written entirely inside the `finally` may still
use its own `break`/`continue`). A name assigned only inside a `try` body is not guaranteed
assigned afterward, even with no `catch`, since anything in the body could raise before
reaching the assignment; the same assignment inside `finally` *does* count, since `finally`
always runs to completion. See
[`conformance/diagnostics/error-checking.em`](../../conformance/diagnostics/error-checking.em)
for both diagnostics side by side.

An uncaught error ends the program with an Emerald stack trace (source file, line, function,
and message) rather than any host-language detail.

## assert

```emerald
assert score > 0
assert score > 0, "score must be positive"
```

`assert` is a compiler-known statement, not a function: it inspects the condition's own
source text and, for a failed equality (`==`/`!=`), both evaluated operands, without
evaluating either side of the comparison twice. A failing `assert` raises `AssertionError`
and stays active in every build, optimized or not.

The caught `error.message` is the optional message argument verbatim if one was given,
otherwise `` assertion failed: `{condition source}` ``. The extra "Left was ...; right was
..." detail for a failed equality, and "The condition was false." when there is no message
and no equality to compare, appear only in the uncaught diagnostic's own explanation line —
not in `error.message` — so code that inspects a caught assertion's message programmatically
sees the condition or the custom text, never the computed operand values. Compare
[`conformance/runtime-errors/assertion.em`](../../conformance/runtime-errors/assertion.em)'s
uncaught rendering against
[`conformance/run/errors.em`](../../conformance/run/errors.em)'s caught
`` catch error: AssertionError { print(error.message) } ``, which prints only the custom
message.

**Raises** nothing beyond `AssertionError` itself — a non-`Bool` condition or a non-`String`
message is a checking-time error, not a runtime one.

## @test and emerald test

```emerald
@test
func add_reports_the_sum() {
    assert add(2, 3) == 5
}
```

`emerald test` discovers every top-level `@test` function and runs each with no parameters
and no result — a test that declares either is a checking-time error. Tests run in
deterministic source order; one failing test is reported without hiding the rest, and each
failure's output names the test, the failing expression, and where it was called from. Entry
statements outside any function are skipped in test mode, while entry-file bindings still
initialize lazily, the first time a test actually reaches them (14.1's ordinary rule).
`emerald test` exits `3` when any test fails, distinguishing that from an ordinary uncaught
error's exit `2`.
