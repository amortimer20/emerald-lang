# Standard-library audit

Status: **audit for the user's decisions** (roadmap item 4, 2026-10-28). Nothing here is built or
promised. Each gap is sorted into **in** (before 1.0), **later** (after 1.0, or when a program asks),
or **out** (deliberately not planned), against rewrite-context 15.1's five tests:

1. it replaces awkward syntax or an error-prone pattern;
2. doing it right needs Unicode, numeric, platform, or runtime knowledge;
3. it is established vocabulary across several languages;
4. it has come up in real Emerald programs;
5. it has clear educational value at very low cost.

The comparison languages are Python, Ruby, C#, and Go, as the handoff asks. Every "missing" below
was checked against a build of main (`6ab709d`); every name is a placeholder for the design plan to
settle, not a decision.

## What exists

Text (`String`, 40 members, `Regex`), numbers (`Int`, `Float`, `Math`), collections (`List`, 60
members; `Dict`; `Set`; `Range`), `Bytes`, `Base64`, `Digest`, files (`File`, `Directory`, `Path`),
dates and times (`Date`, `Time`, `DateTime`, `Instant`, `Duration`, `TimeZone`, `Stopwatch`),
`Random`, `Console` (styling, `table`, `panel`, prompts), `Json`, `Csv`, `Http` (a client), tasks and
channels, `Program` (`arguments`, `sleep`), and the prelude (`print`, `write`, `input`,
`input_maybe`, `random`, `exit`, `assert`). Next to Python's or Go's everyday library it is already
broad; the gaps are mostly small and mostly in text, lists, and the program's surroundings.

## In: recommended before 1.0

Each is small, and each is something a first-course program writes in its first weeks.

| # | Gap | Today | Elsewhere | Tests |
| --- | --- | --- | --- | --- |
| 1 | **Joining a list of strings**, `["a", "b"].join(", ")` | no way but a loop or `reduce` | `", ".join` (Py), `join` (Rb), `string.Join` (C#), `strings.Join` (Go) | 1, 3 |
| 2 | **Character tests**: `letter?`, `digit?`, `whitespace?`, `upper?`, `lower?` on a string | a regex, or comparing code points by hand | `isalpha`/`isdigit` (Py), `char.IsLetter` (C#), `unicode.IsLetter` (Go) | 2, 3 |
| 3 | **A string from code points**, the inverse of `code_points()` | none: a Caesar cipher cannot turn a number back into a letter | `chr` (Py), `chr` (Rb), `char.ConvertFromUtf32` (C#), `string(rune)` (Go) | 2, 3 |
| 4 | **Splitting on whitespace**, `"a  b".words()` | `split(" ")` keeps empty strings between double spaces | `split()` (Py), `split` (Rb), `strings.Fields` (Go) | 1, 3 |
| 5 | **`index_of` on a list** | `find_index` with a block | `index` (Py, Rb), `IndexOf` (C#), `slices.Index` (Go) | 3 |
| 6 | **A list of one value repeated**, for grids and counters | a `for` loop; `Range` has no `map` | `[0] * n` (Py), `Array.new(n, 0)` (Rb), `Enumerable.Repeat` (C#) | 1, 5 |
| 7 | **Appending a whole list**, `items.append_all(more)` | `chain` builds a new list; in place needs a loop | `extend` (Py), `concat` (Rb), `AddRange` (C#), `append(xs, ys...)` (Go) | 1, 3 |
| 8 | **The larger or smaller of two values**, `Math.max(a, b)` | `[a, b].max()`, which is optional and needs `.or(...)` | `max` (Py, Go), `Math.Max` (C#), `[a, b].max` (Rb) | 1, 3 |
| 9 | **A random fraction**, for chances and simulations | `random` takes whole-number ranges only | `random()` (Py), `rand` (Rb), `NextDouble` (C#), `rand.Float64` (Go) | 3 |
| 10 | **Environment variables**, `Program.environment("API_KEY")` | none; an HTTP program has to hard-code its key | `os.environ` (Py), `ENV` (Rb), `GetEnvironmentVariable` (C#), `os.Getenv` (Go) | 2, 3 |
| 11 | **Writing to standard error** | none; error messages mix with output | `print(file=sys.stderr)` (Py), `warn` (Rb), `Console.Error` (C#), `os.Stderr` (Go) | 2, 3 |
| 12 | **Clearing the terminal**, `Console.clear()` | none; text games scroll forever | `Console.Clear` (C#); `os.system("cls")` and similar elsewhere, which is platform knowledge | 2, 5 |

Notes the design plan has to settle:

- **1:** whether `join` is only on `List[String]` (the honest type) or on any list through its
  display form, as Ruby's is.
- **3** has no natural receiver, since `String` is not a value you can reach members on. It might be
  `Int.to_character`-shaped, or a type-level `String` member once there is one.
- **6:** lists are values in Emerald, so `[[0].repeat(3)].repeat(3)` is a safe grid. That avoids
  Python's aliasing trap and is worth a sentence in the guide.
- **8** may be generic over `Ordered` (`Math.max[T with Ordered]`), now that generics exist.
- **11:** the name is open: a prelude `print_error`, or `Console.error`.

## Later: after 1.0, or when a program asks

| Gap | Why later |
| --- | --- |
| Networking beyond the HTTP client: TCP sockets, a small HTTP server | Item 4 already puts networking last, with its own design pass; tasks give each connection a task. **This is the one "later" that item 4 may still want before 1.0; your call.** |
| `count_of(text)` and `last_index_of` on strings | Established (3), but rarer in first programs than 1 to 12. |
| Date patterns, `date.format("d MMMM yyyy")` | Interpolation with `month_name` already covers it, and every language spells patterns differently. Named styles would be the beginner shape. |
| Combinatorics: `permutations`, `combinations`, `product` | Puzzle programs use them (5), but nothing has asked yet. |
| Statistics past `average`: `median`, `mode`, standard deviation | Small and educational (5); `frequencies` and `sort` already make them a short exercise. |
| File facts: `File.size`, modification time; a recursive directory walk | Intermediate programs only. |
| The current directory, the platform's name, running another program | Platform knowledge (2), but no beginner program needs them; running programs raises safety questions. |
| `Int.max` and `Int.min` | Optionals already cover "no best yet". |
| A UUID | Real apps want one; first courses don't. |
| `Math.exp`, `Math.log2`, `Math.hypot` | `Math.e ** x` covers `exp`; the rest are rare. |

## Out: deliberately not planned

| Gap | Why out |
| --- | --- |
| **Ready-made `Stack`, `Queue`, `Deque`, `PriorityQueue`** | The audience's data-structures unit has students build these, with generics. A `List` is a stack (`append`, `remove_last`) and, at classroom sizes, a queue (`remove_first`). **Your call: this is the one "out" that a BFS exercise might argue against.** |
| `printf`-style format strings | Interpolation, `pad_start`, and `format(decimal_places:)` already cover it, and two ways to format is what 15.1 avoids. |
| Arbitrary-size integers | Already out in 15.7 (the numeric zoo). `25.factorial()` says it does not fit, which is a lesson in itself. |
| `assert_equal` and other assertion helpers | `assert(a == b)` already prints the expression that failed. |
| Compression, other text encodings, YAML, TOML, XML | No first-course program needs them; a library can be copied in (14.4). |
| Logging frameworks, threads, processes | `print` is the beginner's log; tasks are the concurrency (15.13). |
| Raw keyboard input, full-screen terminal UI | Parked with `Tui` (15.6): it needs raw mode and a redraw loop. |

## What happens next

The user marks each row in, later, or out. Then a design plan for the "in" set settles names and
shapes, and it is built in slices: text (1 to 4), lists and numbers (5 to 9), and the program's
surroundings (10 to 12), with networking last if it stays in.
