# Prelude

The prelude functions are visible bare in every file, with no import. A file's own
declaration of the same name replaces the prelude's for that file (15.2). This page covers
`print`, `write`, `print_error`, `input`, `input_maybe`, `random`, `random_fraction`, and `exit`. `assert` is documented with
errors and tests, since its behavior belongs beside `raise`/`catch` rather than beside these
seven; the prelude's comparison trait (`Ordered`), its equality traits
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

## print_error(...values) -> Nothing

`print`, for standard error: the same arguments, the same display, and a line break at the
end. Use it for messages about what went wrong, so they stay out of output that is redirected
to a file or piped to another program.

```emerald
const file_name = Program.arguments.first.or("scores.txt")
if not File.exists?(file_name) {
    print_error("No file named #{file_name}")
    exit(1)
}
```

What the program printed before it reaches the terminal first. Console styling follows
[the color policy](console.md#the-color-policy), decided by standard error's own terminal
check, with one limit: a styled string is built from standard output's policy, before anyone
knows where it goes. So `print_error(Console.red("Error"))` is red on a terminal and plain
in a log file (`emerald run game.em 2> errors.log`), but when standard output is redirected
and standard error is not, the string was built plain and stays plain. There is no
`write_error`. See [`conformance/run/print-error.em`](../../conformance/run/print-error.em).

## input() -> String

## input(prompt: String) -> String

In a task, cancelling a standard-input wait raises `CancelledError` and runs cleanup
without waiting for a line. The scheduler keeps the in-flight read; its eventual line
goes to the next input call rather than being lost. Program exit does not wait for that
reader. This applies to `input_maybe` as well.

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

## random_fraction() -> Float

A `Float` chosen at random from `0.0` up to but not including `1.0`, from the same
runtime-managed generator as `random`: `if random_fraction() < 0.3 { ... }` happens about
three times in ten. [`Random`](random.md)'s `next_fraction()` is the seeded form.

## exit() -> Nothing

## exit(code: Int) -> Nothing

Ends the program immediately: `exit()` requests status `0`, and `exit(code)` requests
`code`, which must be `0` through `255`. `exit` is control flow, not a typed error — it is
not catchable, but every pending `finally` still runs on the way out, and normal completion
of the entry file (or an uncaught error) exits on its own without calling it.

**Raises** a `RuntimeError` when `code` is outside `0`–`255`. See
[`conformance/run/exit.em`](../../conformance/run/exit.em) for the cleanup-before-exit order.
