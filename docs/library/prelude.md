# Prelude

The prelude functions are visible bare in every file, with no import. A file's own
declaration of the same name replaces the prelude's for that file (15.2). This page covers
`print`, `write`, `input`, `input_maybe`, `random`, and `exit`. `assert` is documented with
errors and tests, since its behavior belongs beside `raise`/`catch` rather than beside these
six; the prelude's operator traits (`Addable`, `Subtractable`, `Multipliable`, `Divisible`,
`Ordered`), its equality traits
([`Equatable`/`Hashable`](../language/objects-and-traits.md#custom-equality-and-hashing)),
and its display trait ([`Textual`](../language/objects-and-traits.md#display)) belong with
traits in the language guide, since they are adopted by user types rather than called
directly.

## print(...values) -> Nothing

## write(...values) -> Nothing

Both accept zero or more values of any type and display each one the way string
interpolation would — a string as its own text, everything else the same as `to_string()`
or its type's own display, including a type that supplies one by adopting
[`Textual`](../language/objects-and-traits.md#display). Multiple arguments are separated by
one space and evaluated left to right, and the whole line is built before any of it is
written, so a `to_string()` that raises leaves no partial output. `print` appends a trailing
newline; `write` does not, so repeated `write` calls build one line. There is no separator customization; interpolation is the way to build deliberate
prose around a value. See [`examples/greeter.em`](../../examples/greeter.em) and
[`examples/blocks.em`](../../examples/blocks.em) (which uses `write` inside a loop).

## input() -> String

## input(prompt: String) -> String

Writes the optional prompt with no trailing newline, reads one line from standard input, and
returns it with its line ending removed but other whitespace intact. Pressing Enter with
nothing else returns `""`.

**Raises** `InputError` at the end of input, and also if the line read is not valid UTF-8 (so
every `String` a program holds is guaranteed to be Unicode text). See
[`conformance/runtime-errors/input-ended.em`](../../conformance/runtime-errors/input-ended.em).

## input_maybe() -> String?

## input_maybe(prompt: String) -> String?

The same read as `input`, except end of input returns `nothing` instead of raising. Use this
form when reaching the end of the input is an expected outcome to handle rather than a
failure. See [`examples/greeter.em`](../../examples/greeter.em) for the everyday `input`
form and 4.5's optional-handling guide for reading a `String?` result.

## random(range: Range) -> Int

Chooses one `Int` from the given `Range`, uniformly, using a runtime-managed generator. The
range's own bounds decide which values are reachable — `random(1..6)` can return `6`,
`random(0..<10)` cannot reach `10`.

**Raises** a `RuntimeError` when the range is empty. See
[`conformance/runtime-errors/random-empty-range.em`](../../conformance/runtime-errors/random-empty-range.em)
and [`conformance/run/randomness.em`](../../conformance/run/randomness.em), which also shows
`List.random()`, `List.shuffle()`/`shuffle!()`, and the seeded `Random(seed:)` generator —
each belongs to its own receiver's family page rather than to this bare function.

## exit() -> Nothing

## exit(code: Int) -> Nothing

Ends the program immediately: `exit()` requests status `0`, and `exit(code)` requests
`code`, which must be `0` through `255`. `exit` is control flow, not a typed error — it is
not catchable, but every pending `finally` still runs on the way out, and normal completion
of the entry file (or an uncaught error) exits on its own without calling it.

**Raises** a `RuntimeError` when `code` is outside `0`–`255`. See
[`conformance/run/exit.em`](../../conformance/run/exit.em) for the cleanup-before-exit order.
