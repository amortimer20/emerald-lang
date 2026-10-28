# Standard-library additions: design plan

Status: accepted by the user, 2026-10-28, and **built and merged**: slice 1 (text) in PR #49,
slice 2 (lists and numbers) in PR #50, and slice 3 (the program's surroundings) in PR #51. It
covers the twelve gaps the user accepted as "in" from [`stdlib-audit.md`](stdlib-audit.md) the
same day. Each section's "Settled while building" notes record where the result differs from
the proposal.

Each addition is small, and each closes something a first-course program hits in its first weeks.
The plan settles names, shapes, and edge cases, so the slices can be built without reopening them.
The rules it follows are the ones the library already keeps (rewrite-context 15.1):

- a method lives on the value it is discovered from;
- a predicate ends in `?` and takes parentheses (`even?()`, `blank?()`);
- a conversion starts with `to_`;
- names are full words;
- an operation that can miss gives an optional, and one that cannot proceed raises;
- an element-specific list method exists only for the element type it makes sense for, as `sum`
  does for numbers.

## Recommendations at a glance

| # | Gap | Recommendation |
| --- | --- | --- |
| 1 | Joining strings | `join(separator: String = ""): String` on `List[String]` only |
| 2 | Character tests | `letter?()`, `digit?()`, `whitespace?()`, `upper?()`, `lower?()` on `String`, true when the string is not empty and every character passes |
| 3 | Code points to text | `to_character(): String` on `Int`, raising for a number that is not a Unicode scalar |
| 4 | Splitting on whitespace | `words(): List[String]` on `String`, beside `lines()` |
| 5 | Finding an item | `index_of(item: T): Int?` on `List`, for the element types `contains?` accepts |
| 6 | Repeated lists | `repeat(times: Int): List[T]` on `List`, as `String.repeat` |
| 7 | Appending a list | `append_all(items: List[T])` on `List`, in place |
| 8 | Two-value max and min | `Math.max(first, second)` and `Math.min(first, second)`, for any `Ordered` type |
| 9 | A random fraction | `random_fraction(): Float` in the prelude, and `next_fraction()` on `Random` |
| 10 | Environment variables | `Program.environment(name: String): String?`, read-only |
| 11 | Standard error | `print_error(value)` in the prelude |
| 12 | Clearing the terminal | `Console.clear()`, which does nothing when output is not a terminal |

## 1. `join`

```emerald
const names = ["Ada", "Grace", "Alan"]
print(names.join(", "))       # Ada, Grace, Alan
print(["a", "b", "c"].join()) # abc
```

- It is only on `List[String]`. On any other list, the checker says so and shows the fix:
  `items.map { item => "#{item}" }.join(", ")`. Ruby joins anything through its display form, but
  that would make `join` quietly depend on `Textual` (15.1) and on how a struct happens to print.
  Keeping it to strings is honest, and the fix is one `map`.
- The separator defaults to `""`, so `chars().reverse().join()` reads naturally.
- An empty list joins to `""`.
- *Rejected:* `", ".join(names)` (Python's order), because the method belongs to the list you
  discovered it from. `String.join(...)` as a type-level member, because `String` is not a
  namespace a program can reach.

## 2. Character tests

```emerald
const password = "hunter2"
const has_digit = password.chars().any? { character => character.digit?() }
print("A".upper?(), "é".letter?(), " ".whitespace?()) # true true true
```

- These are `String` methods, since Emerald has no separate character type and `chars()` gives
  one-character strings. Each is true when the string is not empty and every character passes,
  as Python's are. So `"abc".letter?()` is true and `"".letter?()` is false.
- `letter?()` uses Unicode's `Alphabetic` property, so `é`, `ß`, and `日` are letters.
- `digit?()` is ASCII `0` to `9` only. Those are the digits `to_int` reads, so `digit?()` never
  says yes to something `to_int` refuses. Other scripts' digits are letters to neither.
- `whitespace?()` uses `White_Space`, the property `trim` already uses.
- `upper?()` and `lower?()` are true when the string has at least one cased letter and every
  cased letter is upper (or lower) case. Characters without case are ignored, so `"A1".upper?()` is
  true and `"1".upper?()` is false, as in Python.
- A "character" here is a grapheme, as everywhere in `String`. A grapheme passes when its first
  code point does: `"é"` written as `e` plus a combining accent is still a letter.
- **Building it:** `src/unicode/tables.zig` needs the `Alphabetic`, `Uppercase`, and `Lowercase`
  derived properties. That means extending `tools/unicode/generate.zig` and regenerating
  deliberately (19.1), with conformance tests against the UCD's own lists.
- *Rejected:* `alphanumeric?()` and `punctuation?()`. They are rarer, and `letter?() or digit?()`
  says the first one out loud.

## 3. `to_character`

```emerald
func shift(letter: String, by: Int): String {
    const start = "a".code_points()[0]
    const position = (letter.code_points()[0] - start + by) % 26
    return (start + position).to_character()
}
print(shift("y", 3)) # b
```

- It is on `Int`, the value you are holding when you need it, and gives a one-character `String`.
  Several numbers become text with `codes.map { code => code.to_character() }.join()`, which item 1
  makes possible.
- A number that is not a Unicode scalar value raises a `RuntimeError` saying why: negative, past
  1114111, or a surrogate (55296 to 57343). The message uses decimal, since Emerald has no
  hexadecimal literals for a reader to compare with. This matches `String.repeat` raising for a
  negative count. There is no `_maybe` form; nothing has asked for one.
- *Rejected:* `to_string` (it already gives `"65"`); `chr` (an abbreviation);
  `String.from_code_points` (no `String` namespace, see item 1).

## 4. `words`

```emerald
print("  the  quick brown ".words()) # ["the", "quick", "brown"]
```

- It splits on runs of `White_Space` and drops the empty pieces, so leading, trailing, and double
  spaces never produce `""`. It sits beside `lines()`, its nearest relative.
- *Rejected:* `split()` with no argument (Python), because `split()` and `split(" ")` would then
  give different answers for the same text, which is a trap.

## 5. `index_of` on a list

```emerald
const queue = ["Ada", "Grace", "Alan"]
print(queue.index_of("Grace")) # 1
print(queue.index_of("Linus")) # nothing
```

- It gives the first match's position, or `nothing`, as `String.index_of` does. It accepts the
  same element types as `contains?` and compares the same way, through `Equatable`.
- `last_index_of` stays "later", as the audit says.
- **Settled while building:** an `Int` argument finds an equal `Float` item, and
  `index_of(nothing)` on a `List[T?]` finds the first absent item, both exactly as `contains?`.

## 6. `repeat` on a list

```emerald
var grid = [["."].repeat(3)].repeat(3)
grid[1][1] = "X"
print(grid) # [[".", ".", "."], [".", "X", "."], [".", ".", "."]]
```

- `[0].repeat(5)` is `[0, 0, 0, 0, 0]`, and `[1, 2].repeat(2)` is `[1, 2, 1, 2]`, the same meaning
  as `"ab".repeat(2)`. A negative count raises, with `String.repeat`'s wording.
- Lists are values, so every row is its own. The guide says so, because this is exactly where
  Python's `[[0] * 3] * 3` shares one row three times.
- *Rejected:* `map` on `Range`, a bigger change that is not the beginner's question here.
- **Settled while building:** the wording is `` a List cannot be repeated -2 times `` with
  "Repeat it 0 or more times; 0 gives an empty List." An empty list repeated any count is `[]`
  at once, and a result too large to address runs out of memory, as `String.repeat` does.

## 7. `append_all`

```emerald
var all_scores = [90, 85]
all_scores.append_all([70, 100])
print(all_scores) # [90, 85, 70, 100]
```

- It changes the list in place and gives nothing, exactly like `append`, and it sits beside
  `append` in completion. `chain` stays the way to build a new list without changing either one.
- Appending a list to itself (`items.append_all(items)`) appends what the list held before the
  call. The value semantics already guarantee that, but it gets its own test.
- *Rejected:* `extend` (Python's name says less); `+` on lists, which is a language question that
  stays in the generics friction log.
- **Settled while building:** `extend`, `concat`, `push_all`, and `add_all` are familiar names
  whose diagnostic points to `append_all`, as `index` and `indexOf` point to `index_of`. A
  `List[Float]` takes a `List[Int]` literal's items widened, as `append` does.

## 8. `Math.max` and `Math.min`

```emerald
const best = Math.max(best_so_far, score)
print(Math.min(3, 2.5)) # 2.5
print(Math.max("pear", "apple")) # pear
```

- They are generic, `Math.max[T with Ordered](first: T, second: T): T`, so they work for numbers,
  strings, dates, and a program's own `Ordered` types. Whole numbers stay honest: `Math.min(3, 2.5)`
  infers `Float`, as generics already do (11.3).
- Exactly two arguments. For more, `List`'s `max()` already exists. Emerald has no variadic
  functions, and this is not the place to start.
- When the two are equal, both give `first`. It only matters for an `Ordered` type whose
  `compare` calls different values equal, and then it should be stated.
- They go in `Math`, which until now held only `Float` functions. `Math.Max` is C#'s, Java's, and
  JavaScript's spelling, and it is the one a beginner searches for.
- **Building it:** `Math` is native, and it has no generic members yet. The checker can treat these
  like the other scalar-generic natives (`compare`, 11.3), or `Math` can gain prelude-written
  generic functions. The slice decides, and records why.
- *Rejected:* `a.max(b)` as a method (Rust). It reads as "a's maximum" to a beginner.
- **Built (slice 2):** the checker special-cases them, like the scalar comparison members,
  rather than giving `Math` prelude-written generic functions. `Math` is native: its members
  resolve to `Math` keys in the resolver, and a prelude function would need a second route
  from `Math.max` to a hidden prelude name, plus reach and display work, for no behaviour the
  special case lacks. They sit in `Type.math_functions` marked `ordered`, so resolution, the
  "has to be called" diagnostic, and the parity test treat them as `Math` members. The checker
  unifies the two argument types as a list literal does and accepts Ints, Floats, Strings,
  `T with Ordered`, and types adopting `Ordered`; the interpreter orders the values with
  `List.max`'s ordering, a struct's through its `compare`.
- **Settled while building:** a `NaN` argument raises (`` `Math.max` cannot compare NaN ``),
  as `List.max()` does, rather than giving IEEE's answer, which would depend on the argument
  order and break "equal values give `first`".

## 9. `random_fraction` and `next_fraction`

```emerald
if random_fraction() < 0.3 {
    print("A rare find!")
}
const generator = Random(42)
print(generator.next_fraction()) # the same fraction every run
```

- It gives a `Float` from `0.0` up to but not including `1.0`, which is every language's
  convention. The seeded form sits on `Random` beside `next`, so a test can repeat it.
- It is a new prelude function rather than a change to `random`, because Emerald has no
  overloading (21), and `random` already takes a range. Float ranges do not exist, and this is not
  a reason to add them.
- *Rejected:* `chance?(0.3)`. It is pleasant, but a simulation needs the number itself, and a
  comparison with `<` teaches more.
- **Settled while building:** both use Zig's `std.Random.float(f64)` on the generator `random`
  and `next` already use; `next_fraction` advances a `Random`'s state exactly as `next` does,
  so the two interleave repeatably. A program's own `random_fraction` gets the hiding warning
  (`conformance/diagnostics/random-fraction.em`).

## 10. `Program.environment`

```emerald
const key = Program.environment("WEATHER_KEY").or("")
if key.blank?() {
    print_error("Set WEATHER_KEY to your API key first.")
    exit(1)
}
```

- It reads one variable and gives `nothing` when it is not set. It never sets a variable: changing
  the environment is a process-wide side effect no beginner program needs. Section 15.10's sentence
  that "Emerald code cannot read or alter environment variables" becomes "cannot alter", and the
  HTTP client still applies proxy settings privately.
- A variable that is set but not valid UTF-8 raises an `EncodingError`, as reading such a file
  does.
- It sits on `Program`, beside `arguments`, as the other way a program learns about how it was
  started.
- *Rejected:* `env` (an abbreviation); a dictionary of every variable (`Program.environment["X"]`),
  which invites iterating over secrets for no first-course reason.

## 11. `print_error`

```emerald
const file_name = Program.arguments.first.or("scores.txt")
if not File.exists?(file_name) {
    print_error("No file named #{file_name}")
    exit(1)
}
```

- It writes to standard error with `print`'s exact display rules and a line break. There is no
  `write_error` until a program asks for one.
- It is a prelude function because it is `print`'s twin, and `print` is in the prelude. The prelude
  grows from six functions to eight with item 9; both earn it by frequency.
- Console colors still follow the policy in 15.6, decided for standard error by standard error's
  own terminal check, so `Console.red("Error")` is colored on a terminal and plain in a log file.
- **Upgrading:** a program that already declares its own `print_error` or `random_fraction` now
  gets 14.2's "hides a built-in" warning. The release notes say so.
- *Rejected:* `Console.error`, because a beginner reaches for a `print` first, and `warn` (Ruby),
  because "warning" already means something else in Emerald.

## 12. `Console.clear`

```emerald
Console.clear()
print("Round 2")
```

- It clears the screen and puts the cursor at the top left, when standard output is a terminal.
  When output goes to a file or a pipe it does nothing, so a test's output and a redirected run
  stay clean. That matches what `Console`'s color already does.
- It does not depend on `--color` or `NO_COLOR`, which are about color, not the screen.
- On Windows it uses the same virtual-terminal mode `Console` already turns on.
- *Rejected:* `Console.clear_line` and cursor movement. They belong to the parked `Tui` (15.6).

## Slices

Each slice comes with:

- native or prelude code;
- `src/builtins.json` entries, which the parity test checks;
- conformance cases for every rule and error above;
- rewrite-context updates (15.x) and the reference pages in `docs/library/`;
- the website's pages, with every example run.

1. **Text:** items 1 to 4, with the Unicode table regeneration in item 2.
2. **Lists and numbers:** items 5 to 9.
3. **The program's surroundings:** items 10 to 12.

The release notes gain one "New in the library" section listing all twelve, and an upgrading note
for item 11's names.

## Settled while building

Slice 3 (items 10 to 12):

- **`print_error` takes any number of values**, like `print`, rather than exactly one. The plan
  wrote `print_error(value)` but asked for `print`'s exact display rules, and those include
  several values separated by one space; a beginner who changes `print` to `print_error` should
  not meet a new arity rule.
- **Per-stream color is half possible.** Styling is added when `Console.red` builds its string,
  from standard output's policy, before anything knows the string is going to standard error.
  Standard error's policy is resolved separately by its own terminal check, and `print_error`
  takes the styling back out (as `Console.plain` does) when standard output is styled and
  standard error is not, which is the plan's "plain in a log file" case
  (`emerald run game.em 2> errors.log`). The reverse, styling text that was built plain because
  standard output is redirected, cannot be done without changing what `Console.red` returns, so
  it stays plain. Recorded in 15.2.
- **`print_error` flushes standard output first**, then writes and flushes its own line, so a
  terminal shows lines in the order the program wrote them.
- **Embeddings and the conformance runner** give no separate standard error by default, and
  `print_error` then writes to the one output stream, in order. `run/print-error.em` therefore
  shows its lines inline; `emerald.zig`'s unit tests check the separate stream and the styling.
- **`Program.environment` with an empty name, or one holding `=` or NUL**, gives `nothing`
  rather than raising: no variable can have such a name, so it is simply not set. Its
  `EncodingError` message names the variable. The conformance runner provides no environment,
  so a set variable and a non-UTF-8 one are unit tests (POSIX only, since Windows has no way to
  give a fixed environment block).
- **`Console.clear` honors `TERM=dumb`**, which the plan did not mention. It stays independent
  of `--color` and `NO_COLOR` as planned, but a dumb terminal cannot move its cursor and would
  print the sequence as text. The sequence is `ESC[2J ESC[H`; scrollback is left alone.
- **On Windows, `Console.clear` turns on virtual-terminal mode lazily**, the first time it
  clears, instead of at startup, so 15.6's rule that forced styling never configures a console
  holds for every program that does not clear.
- **No familiar names.** The familiar-name tables cover value members only, not `Program`'s
  type-level members, so `getenv`/`env` get the ordinary unknown-member error, whose list of
  members now includes `Program.environment`.

## Left out on purpose

- Every row the audit marked "later" or "out".
- `_maybe` forms and extra parameters nobody has asked for: `join` with a final `"and"`,
  `words(separator:)`, a `count` parameter for `index_of`, and a seed range for `next_fraction`.
- Any change to an existing member's meaning. Every addition is a new name, so no program that
  runs today changes behaviour. The only effect on existing programs is item 11's hiding warning.
