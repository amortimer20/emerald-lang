# Current handoff

Updated: 2026-09-15. Range part 1 is complete: integer ranges are first-class immutable values, the
shared runtime Range model feeds `for` loops without breaking loop semantics, and the recursion stress
case remains green with a larger reserved stack for the deep host-guarded interpreter runs.

## Current milestone

Completed in this pass: the Range/value implementation now accepts literal and method forms such as
`1..5`, `1..<5`, `start.up_to(end)`, and `start.down_to(end)` as immutable `Range` values, with the
checked Range surface (`count`, `empty?()`, `step(distance)`, `reverse()`, and `to_list()`) aligned to
Emerald's rewrite-context rules. The shared Range representation is consumed by `for` loops while
preserving the existing upward-counting semantics and overflow-safe iteration. The recursion stress test
for a 250-level nested body and 1,000 calls is also kept green by reserving a sufficiently large stack
for the interpreter thread.

The next step is to keep the Range slice narrow and move on to the remaining deferred rich collection
methods, without broadening into the collection vocabulary that the rewrite context intentionally leaves
for later slices.

Slices 1 through 11 of section 20 are complete, plus a loop slice the user approved
inserting before slice 8, a string slice the user chose to do before slice 9, an
optionals slice the user chose to do before the project slice, a tuple slice split out
of section 8's collections because dictionaries need it (8.6 iterates a dictionary as
`(key, value)` tuples and states there is no second implicit calling convention), and the
dictionaries and sets slice that finishes section 8's collections. Section 20 was renumbered
during the callable slice: the old slice 9 bundled closures with the collector, and they
are now slice 9 (callables) and slice 10 (the managed heap). The whole frontend pipeline of
section 19.2 exists: source manager, lexer, parser, name resolver, type checker,
interpreter.

The object model now has hoisted structs with required `var` and `const` stored fields.
Their generated constructor takes one positional argument per field in declaration order;
field reads, numeric widening into fields, structural display and equality, namespace
identity, qualified type annotations, recursive dictionary-key eligibility, and value
semantics for values held by fields all work end to end. Fieldless structs retain their
generated zero-argument constructor. Assignment now reaches through a path of indices and
struct fields, as in `line.start.x = 1`, `points[0].x = 1`, and `bag.values.append(2)`,
with copy-on-write on the struct instance and section 4.3's `const` checked at every field
the path passes through, not only at the root binding. A struct may declare one custom
constructor that replaces the generated one; inside it `self` is the value being built,
each field must be set on every path before the constructor finishes, a field may be read
once it is set, and `self` as a whole may be used once every field is. Structs have instance
methods; the checker works out from each body whether it changes `self`, and a changing
method can only be called on something that can change. Computed properties work, read-only
and writable, with nested mutation through one rejected. Section 7.3's default parameters and
named arguments work for functions, methods, and constructors, and fields have defaults that
make them optional in the generated constructor. Type-level functions and fields work
(`func Vector2.origin()`, `var Player.count = 0`), set up lazily the first time the type is
reached. Members whose names start with `_` are private to their type's braces, and a
struct method without parentheses is a function value holding its own copy of the receiver.
Structs are complete. Classes have everything structs have, as shared objects: assignment
and passing share, `const` stops at the first object, identity equality, blocks that use
`self`, and cycles the collector reclaims. Classes inherit: `extends`, `super(...)` and
`super.name`, `@override`, `@abstract` classes and methods, subclass objects usable as their
base class, and each object running its own class's version of a method or property. `is`
tests an object's class at runtime and narrows a name within the branch it proves, and
every value has `type_name`. Traits work: requirements and defaults, adoption by structs and
classes with `with`, traits building on traits, conflict and conformance checking, values
seen through a trait with their own behavior, and `Trait.method(self)`. `Self` works in
method signatures, and `+`, `-`, `*`, `/`, and ordering work on types that adopt the
prelude's `Addable`, `Subtractable`, `Multipliable`, `Divisible`, and `Ordered`. Enums work,
with methods, properties, type-level members, and traits, and so does `case`/`when` as a
statement and as a value, with coverage of enum and `Bool` subjects. The object model of
section 20's slice 12 is complete.

Slice 13 is complete. `Error` is the prelude root for typed error values; compact subclasses
whose only stored state is its message get one-message construction. `raise`, typed and
untyped `catch`, bare re-raise, and `finally` work through ordinary calls and runtime
failures, with cleanup on normal completion, return, and failure. Interpreter-detected
errors are catchable as
`RuntimeError`. A changing method or setter that raises returns its receiver to its place,
with completed mutations still visible, rather than leaving the place empty. `assert` is
compiler-known, remains active in optimized builds, accepts an optional comma-separated
message, and reports both evaluated operands for a failed equality without evaluating them
twice. Top-level `@test` functions are discovered by `emerald test`;
entry statements are skipped, all tests run in deterministic source order, failures do not
hide later tests, and status 3 distinguishes test failures.

Slice 14 is in progress. Part 1 adds the settled `Int` vocabulary: `abs`, `clamp`,
`between?`, sign and parity predicates, `multiple_of?`, `digits`, `gcd`, `lcm`,
`factorial`, and `to_float`; the existing `to_string` now lives in the same checked method
table. The runtime handles the asymmetric minimum Int without host overflow, checks all
unrepresentable results, and gives value-specific diagnostics for bad bounds, a zero
divisor, and factorial's domain. The rewrite context records the edge semantics. The
counting forms `times`, `up_to`, and `down_to` stay with the later range-values part; their
existing `for`-header forms are unchanged.

Part 2 adds the settled `Float` vocabulary: the shared numeric methods, `floor`, `ceil`,
`round`, `round_to`, `truncate`, the three classification predicates, and `to_int`; the
existing `to_string` is checked through the same table, and `Float.infinity` and
`Float.nan` expose the two special values. Rounding-to-Int checks finiteness
and the exact asymmetric bounds before invoking Zig's conversion. `round_to` accepts
positive and negative decimal places, ties away from zero, and defines its behavior beyond
binary64's decimal range. Float method arguments perform Emerald's ordinary `Int` widening
at runtime as well as in the checker. A conformance case now reaches section 8.3's NaN-key
guard through strict string conversion, retiring the stale claim that no Emerald program
could produce NaN.

The first implementation evaluated `Float.infinity` and `Float.nan` directly in the
interpreter's recursive expression switch. In Debug that enlarged the hot stack frame
enough to fail the existing test of 1,000 calls whose bodies are nested 250 levels deep.
`evaluateMember` now isolates qualified constants and ordinary properties from that frame;
the stress test passes again.

Part 3 adds the focused String editing and layout vocabulary: `insert_at`,
`remove_prefix`, `remove_suffix`, `collapse_repeats`, `partition`, and the three padding
methods. Every index and width is in graphemes; matching remains canonical, but removals
and partition keep the original bytes of receiver portions. `partition` returns
`(before, match, after)`, or `(text, "", "")` when absent. Padding has an optional
one-grapheme fill of a space, refuses empty or multi-grapheme fills, and puts an odd center
fill on the end. Its new conformance coverage includes Unicode, absent matches, defaults,
diagnostics, and a pedagogical runtime error.

Part 4 starts the rich collection vocabulary with List value transformations:
`take`, `drop`, `reverse`, and `unique`, plus the in-place `reverse!` and
`unique!` counterparts. Value forms create a new list, retaining their elements and leaving
the receiver unchanged; bang forms use the existing copy-on-write mutation path. `take` and
`drop` accept zero and safely clamp an overlarge count, while a negative count raises a
clear error. `unique` uses Emerald equality and keeps each value's first occurrence in
input order. The conformance cases cover values, copy-on-write, type and arity errors, and
negative counts.

Part 5 adds List `filter` and `reject`. Both use an eager `func(Element): Bool` predicate,
run it once per item in input order, and return a new List without changing the receiver.
`filter` retains accepted items and `reject` retains rejected ones. The existing higher-order
call path therefore supplies ordinary closure captures, nested patterns, errors, and stack
traces without a second callback implementation. Dictionary and Set variants remain
deferred with their broader transformation work.

Part 6 adds `each_with_index` to Lists, Dictionaries, and Sets. Its block receives each
ordinary logical item and then a zero-based `Int` position; dictionary entries remain the
single destructurable `(key, value)` first argument. It runs eagerly in the collection's
deterministic order, returns `Nothing`, and uses the established higher-order execution path.
The conformance cases cover all three collection shapes plus the block arity and missing-block
diagnostics.

Part 7 adds List `reverse_each`. It visits the held input from last to first, once per item,
returns `Nothing`, and leaves the List unchanged. Its arity and missing-block diagnostics also
led to a small shared diagnostic improvement: a callback-method help example now names the
method the reader actually called. Dictionary and Set reverse traversal remains deferred.

Part 8 adds the predicate questions `any?`, `all?`, `none?`, `one?`, and `count_where` to
Lists, Dictionaries, and Sets. The `Bool` predicate receives each collection's ordinary
logical item, with a dictionary's tuple entry unchanged. The four questions short-circuit
when their result is decided; `count_where` visits all items. Empty inputs give `false`,
`true`, `true`, `false`, and `0`, in that order. Conformance covers all collection shapes,
empty inputs, each short-circuit boundary, predicate types, and missing blocks.

Part 9 adds List `take_while` and `drop_while`. Both test the initial List prefix with a
`Bool` predicate. `take_while` returns the matching prefix; `drop_while` returns the suffix
starting at the first failure and never invokes its predicate on that suffix. Both allocate a
new List and leave the receiver unchanged. Conformance covers prefix and suffix boundaries,
empty Lists, callback counts, type errors, and missing blocks. Dictionary and Set forms are
deferred with their remaining callback vocabulary. The shared evaluator also derives a safe
fallback item kind for an already-diagnosed invalid Dictionary or Set call, so diagnostics do
not turn into a host crash while the compiler continues checking the file.

Part 10 audits the previously implemented List endpoint properties. `first` and `last` have
returned `Element?` since the optionals slice and are covered by its present and empty-list
conformance cases. The audit adds a direct correction for `list.first()` and `list.last()`:
they are read-only properties, like `count`, and must be written without parentheses.

Part 11 adds List `flat_map`. Its callback must return a List; each produced List is flattened
one level into a new result List, preserving input and produced-List order. Empty produced
Lists add nothing, and neither the receiver nor the produced Lists change. The evaluator grows
the result as it learns each produced List's size and safely completes already-diagnosed
non-List callback results rather than crashing during diagnostic collection. An optional List
result is rejected rather than treated as empty. Conformance covers order, callback count,
empty input, result type, missing blocks, and that optional boundary. Dictionary and Set forms
remain deferred.

Part 12 adds String `code_points()` and `bytes()`. Both return `[Int]`: the former gives the
Unicode scalar values of the stored spelling, while the latter gives its exact UTF-8 octets.
They deliberately expose advanced representation details without introducing a premature
`Byte` type; `chars()` remains the grapheme-aware operation for ordinary text. Conformance
covers an accent written with a combining mark and an emoji, plus the two UTF-8 bytes of `é`.

Part 13 adds List `filter_map`. Its block returns one optional value for each input item;
present values enter a new List in input order and `nothing` is omitted. It does not flatten:
a block returning `[Int]?` produces `[[Int]]`. The checker requires an optional result and
directs an always-present block toward `map`; the evaluator retains a present result directly
and releases `nothing`. Conformance covers callback count, unchanged input, empty input,
nested List results, a non-optional block, and a missing block. Dictionary and Set forms stay
deferred.

Part 14 adds List `sum()` for `[Int]` and `[Float]`. It returns the matching numeric type,
visits items from left to right, and gives `0` or `0.0` for an empty List. Int accumulation
checks every addition for overflow; Float accumulation retains the ordinary `Infinity` and
`NaN` behavior. Non-numeric Lists receive a correction toward mapping to numbers first.
Conformance covers both element types, empty Lists, special Floats, static misuse, the
no-cascade arity boundary, and an Int overflow diagnostic.

Part 15 adds List `min()` and `max()`. They return `T?`: `nothing` for an empty List, or the
first tied item with the requested extreme. Ints, Floats, Strings, and user types adopting
`Ordered` use their ordinary comparison contracts. Optional elements are rejected so that
`nothing` stays the unambiguous empty-List result; `filter_map` is the correction. NaN is
rejected even as the only element, because it has no order. Conformance covers numeric,
String, empty, and custom `Ordered` Lists, type and arity errors, optional elements, and the
NaN runtime diagnostic.

Part 16 adds List `average()` for `[Int]` and `[Float]`. It returns `Float?`, because a
whole-number List can have a fractional mean; an empty List returns `nothing`. Each Int
widening and all Float arithmetic follow the ordinary Float rules, including `Infinity` and
`NaN`. Conformance covers both numeric element types, empty Lists, special Floats, static
misuse, and the no-cascade arity boundary.

Part 17 adds List `reduce(initial) { accumulator, item => ... }`. It evaluates its initial
value once, returns it unchanged for an empty List, and otherwise calls the block once per
item from left to right, carrying each result forward as the next accumulator. The initial
value establishes the accumulator and result type, which can differ from the List element.
The receiver's items stay fixed for the reduction even when the block changes a captured List
binding. `reduce_right` and Dictionary and Set forms remain deferred.

Part 18 adds List `min_by` and `max_by`. A block provides one ordered key per List item while
the selected item remains the result. They return `T?`, keep the first tied item, require
present List elements and keys, and reject a `NaN` key with the same pedagogical ordering rule
as ordinary extrema. Conformance covers Int, Float, String, custom `Ordered`, empty, ties,
static misuse, optional boundaries, and the NaN runtime diagnostic.

Part 19 adds List `min_max()`. It returns `(T?, T?)` after one left-to-right traversal: the
first tied minimum and maximum, or `(nothing, nothing)` for an empty List. It accepts the same
ordered element types as `min` and `max`, and preserves their optional-element and `NaN`
boundaries. Conformance covers numeric, String, custom `Ordered`, empty, type and arity
errors, optional elements, and the NaN runtime diagnostic.

The next focused standard-library part should consider sequence shape methods such as `zip`.

A bounded adversarial review of Slice 14 parts 1–12 found no defect. Small programs in Debug
and ReleaseSafe verified snapshot traversal when callbacks mutate their captured List or
Dictionary receiver, predicate short-circuit boundaries, one-level `flat_map`, Unicode scalar
and UTF-8 byte output, numeric limits, copy-on-write through filtered and flattened nested
Lists, and canonical String equality in `unique`. The review also confirmed that a `const`
collection refusing a mutation is the deliberate section 4.3 value-freezing rule, rather than
a List-method bug. Both complete test suites pass in Debug and ReleaseSafe.

Functions work: declarations, calls, returns, recursion, hoisting, return-type inference,
nested functions, and stack traces on runtime errors. Section 7 is complete apart from
capturing built-in methods (7.4). Loops work: `while`, `for` over an `Int` range, `break`,
`continue`, and the trailing `if` guard. Lists work: literals, indexing, element assignment,
the essential methods, equality, printing, and `for`, with value semantics through
copy-on-write. Strings work: literals with escapes and interpolation, triple-quoted
layout, Unicode-aware counting, indexing, iteration, comparison, and case mapping, the
section 9.2 methods that need no optionals, and `input` and `write`, so section 2's first
program runs. Callables work: lambdas with inferred or written parameter types, closures
that capture by reference, function types, named functions as values, the trailing-block
call form, and `each` and `map`. Optionals work: `T?`, `nothing`, narrowing by comparison
against `nothing`, `.or(...)`, and the vocabulary that needed them — `first`, `last`,
`find`, `find_index`, `index_of`, the `_maybe` parsers, and `input_maybe`. Projects work:
a directory with a `main.em` is a program of many files, directories are namespaces,
`using` shortens them, a leading underscore keeps a name inside its file, and a file that
is not the entry initializes once, on first use. Tuples work: the `(String, Int)` type and
`("score", 10)` literal, zero-based positions, equality position by position, and
unpacking in declarations, `for` bindings, block parameters, and assignment, with nested
patterns in all of them. Dictionaries
and sets work: `[String: Int]` and `{String}`, their literals, bracket lookup producing an
optional, bracket assignment, insertion order, equality by contents rather than order, and
the essential vocabulary of 8.5. Memory is
managed: reference counting reclaims promptly
and section 19.5's mark-and-sweep collector reclaims the cycles counting cannot, so a loop
that keeps making blocks runs in flat memory. Every expression has a static type before
execution and
definite assignment is proved through control flow. Failures that cannot be known
statically travel as typed Emerald errors and may be handled by the program.

## Completed foundation

- The .NET prototype is archived under `legacy/dotnet-v0/`, tagged `dotnet-v0-final`.
- [rewrite-context.md](rewrite-context.md) is the canonical language and architecture
  baseline. The implementation host is Zig.
- Zig `0.16.0` is pinned through [mise.toml](../mise.toml) and
  [toolchain/zig-version.txt](../toolchain/zig-version.txt), verified by
  [tools/check-toolchain.sh](../tools/check-toolchain.sh).
- Shared agent instructions are committed in `AGENTS.md` and `CLAUDE.md` (`f3c38cb`).

## Pre-implementation decision pass

The user asked for a judgment call on the remaining open design questions, prioritizing
beginner friendliness, sound design, and expressive syntax. Seven decisions were settled
and recorded in the rewrite context, each in its normative section plus a summary table in
section 22 under "Pre-implementation decision pass":

- `Int` is 64-bit signed with checked overflow; `Float` is IEEE-754 binary64 (4.2, 5.3).
- The optional type keeps the postfix `T?` (4.2). Its clash with `?`-suffixed identifiers
  is lexical: the lexer emits `Int?` as one identifier token and the parser splits the
  trailing `?` in type position. 4.2 records the rule and a required conformance test.
- Optionals never nest; lossy operations get documented unambiguous companions (4.5, 8.3,
  8.6).
- Overloading is deferred; named factory functions replace overloaded constructors, and
  mixed-type operators are deferred with it (7.3, 10.2, 11.5, 21).
- Type declaration bodies are braced only; the block-free to-EOF form is removed (10.6,
  14.3).
- Struct method capture keeps its value semantics and gains a teaching equivalence (7.5).
- String normalization happens at comparison; construction preserves the original bytes
  (9.2).

Section 24 no longer lists the optional spelling as an open roadmap item.

## Implemented so far

- `build.zig` provides `zig build`, `zig build test`, and `zig build run`.
- `src/Project.zig` finds and loads the files a program is made of, which is section
  14.1's rule and nothing more: the file alone, unless its own directory holds `main.em`,
  in which case every `.em` file under that directory comes with it. It derives each
  directory's namespace and reports one that cannot be a name.
- `src/Source.zig` is the immutable source-file record: UTF-8 with byte-order mark removal,
  LF and CRLF line handling, byte-offset spans, and one-based line and scalar-column
  mapping. It also locates the first invalid UTF-8 sequence and its span.
- `src/Diagnostic.zig` renders the canonical four-part shape from section 17.1, with the
  underline measured in scalars so it aligns past multi-byte characters. A runtime error
  also carries a stack trace, innermost call first, with runs of identical frames
  summarized.
- `src/Token.zig` holds the token kinds, the keyword table, and `canEndExpression`, which
  is the continuation-token list section 3.1 refers to. The switch is exhaustive, so a new
  kind cannot be added without classifying it.
- `src/Lexer.zig` produces tokens with spans: names, keywords, numbers, the three string
  forms, comments, operators, statement-terminating newlines, and EOF.
- `src/Ast.zig` is the syntax tree, free of runtime values so a future backend consumes the
  same tree the interpreter does.
- `src/Parser.zig` parses statements and expressions with section 5.3's precedence, and
  bounds nesting and tree height so no later pass can exhaust the host stack.
- `src/Resolver.zig` is name resolution: scopes, declarations, hoisting, and the section 6.1
  rules. These belong here rather than in the interpreter because they are properties of
  the text rather than of a run. It also records, per function, which module variables it
  reads and which functions it calls, for the checker.
- `src/Type.zig` is the static type representation, its compatibility rules, function
  signatures, and the list method table the checker and interpreter share.
- `src/Checker.zig` is type checking and flow analysis: inference, annotations, operand
  errors, section 4.1's definite assignment, and everything section 7 asks of functions.
- `src/Value.zig` holds `Nothing`, `Bool`, `Int`, `Float`, and lists, implements section
  9.4's display rules, and compares and orders values.
- The section 10 sub-slices so far carry user-defined struct identity, required stored
  fields, assignment through field paths, and custom constructors through the AST, resolver,
  checker, interpreter, and runtime representation. Structs are hoisted, constructible,
  readable field by field, printable, structurally comparable, and eligible as stable keys
  when every field recursively qualifies.
- `src/Heap.zig` owns list buffers, string texts, scope environments, closures, and struct
  instances:
  reference counts, copy-on-write, and section 19.5's mark-and-sweep collector, which walks
  the lists of every live object and reclaims the cycles counting cannot.
- `src/unicode.zig` is Emerald's Unicode: grapheme clusters (UAX #29), NFC normalization
  and its quick check (UAX #15), full case mapping with Final_Sigma, and identifier and
  whitespace classes. Its data is `src/unicode/tables.zig`, generated from Unicode 17.0.0
  by `tools/unicode/generate.zig`; `src/unicode/test/` embeds Unicode's conformance data.
- `src/strings.zig` holds section 9's string operations on UTF-8 bytes: character-aware
  searching, splitting, trimming, substrings, and strict number parsing.
- `src/Interpreter.zig` evaluates, applying section 5.3's result types and failure modes,
  and guards the host stack. Block and call scopes come from the general allocator and are
  reused once emptied, so a running loop does not allocate.
- `src/emerald.zig` is the library root. `check` and `run` share one pipeline that stops at
  the first stage to report anything, which is section 17.2's rule against cascades. The
  pipeline runs on a thread with a large reserved stack.
- `src/main.zig` implements `emerald check` and `emerald run` with the section 18.1 exit
  codes, including `2` for an uncaught runtime error and `70` for an internal failure. It
  chooses the fast `smp_allocator` outside Debug builds; see the loop decisions below.
- `conformance/` holds the suite required by sections 19.6 and 23: cases written in Emerald
  with expected results, run by `src/conformance.zig` under `zig build test`. Cases in
  `lexical/` must tokenize cleanly, `diagnostics/` must match their `.expected` exactly,
  `run/` must print theirs, `runtime-errors/` must fail with theirs, and `format/` must
  come back exactly, with formatting that output again a no-op. See
  [conformance/README.md](../conformance/README.md) for how to add one.
- `src/Formatter.zig` is section 18.3's canonical formatter, `emerald.zig`'s
  `formatProject` the pipeline that reaches it, and `main.zig`'s `format`/`format --check`
  the CLI. See "Formatter decisions worth knowing" below.
- `src/Repl.zig` is section 18.4's `emerald repl`, and `main.zig`'s `executeRepl` the CLI
  entry point. Unlike every other stage, it is not `emerald.zig`'s: it calls the existing,
  unmodified `emerald.run` directly rather than adding anything to the shared pipeline. See
  "REPL decisions worth knowing" below.
- `src/Lsp.zig` is section 18.5's `emerald lsp` (its first slice — live diagnostics,
  document symbols, format on save; see "LSP decisions worth knowing" below for what is
  deliberately not built yet and why), and `main.zig`'s `executeLsp` the CLI entry point.
  Like `Repl.zig`, it calls `emerald.check`/`Lexer`/`Parser`/`Formatter` directly rather
  than adding anything to the shared pipeline.

Section 20's slice 15, part 1 (the canonical formatter) is complete, and its adversarial
review (structs, classes, traits, enums, `case`, `try`/`catch`, tuples, destructuring,
dictionaries, sets, lists, lambdas, `using`/qualified names, optional and function types,
and every literal form, each attacked with small `.em` programs in Debug and ReleaseSafe)
found and fixed two real bugs, both `runtime-errors`-grade — a formatted program that no
longer parsed at all — described in "Formatter decisions worth knowing" below. `emerald
format <path>` and `emerald format --check <path>` format every file of whatever project
`path` names (14.1), exactly as `check`/`run` see the same project, refusing to write
anything if any file does not lex or parse safely (18.3). Every file under `examples/`
round-trips byte for byte; the whole `conformance/` corpus (407 files) formats without
crashing and is idempotent; every `conformance/run/` program still runs to the same output
after being formatted; and `zig build test` passes in Debug and ReleaseSafe with
`conformance/format/` cases (including one added by the review), `Formatter.zig`'s own unit
tests, and CLI contract tests for the new command alongside everything else. The REPL and
LSP remain queued to follow the formatter, per the roadmap; see "Next concrete step".

`src/Repl.zig` is section 18.4's `emerald repl`, complete. It keeps declarations and
values across entries, prints a bare expression's value, enforces the ordinary binding
rules (redeclaration and `const` reassignment rejected, `var` reassignment allowed) with
no REPL-specific logic at all, and clears with `:reset`. See "REPL decisions worth
knowing" below for how, and for one subtle, genuinely hard-won bug found while building
it.

`src/Lsp.zig` is section 18.5's `emerald lsp`, its first slice: JSON-RPC over stdio,
live diagnostics, document symbols, and format on save. Three of the section's seven
features — hover, go to definition, and find references — need infrastructure that
does not exist yet (an offset→AST-node lookup, and a general per-expression type map
where today only a few narrow expression kinds are recorded), safe rename needs
find-references first, and completion needs the parser to recover from a broken
construct by keeping a partial node rather than discarding the whole enclosing
statement, as it does today. All five are deliberately not advertised in this slice's
`initialize` capabilities rather than answered approximately. See "LSP decisions worth
knowing" below.

### LSP decisions worth knowing

- **`std.json.Stringify.write`'s reflection serializes a plain Zig struct or slice
  literal directly, so outgoing messages never need to be built as a `std.json.Value`
  tree by hand** — `.{ .jsonrpc = "2.0", .id = id, .result = .{ .capabilities = .{ ... } } }`
  passed straight to a small `writeMessage` helper is the entire response. The one place
  a `std.json.Value` is still used directly is passing a request's `id` back unchanged:
  since it may be a JSON number or a JSON string and arrives as a dynamic `Value`,
  embedding that same value in the outgoing struct literal (`Value` implements its own
  `jsonStringify`) reproduces whichever it was without the server ever needing to care
  which.
- **Incoming messages stay as the dynamic `std.json.Value` tree, read by hand
  (`.object.get("method").?.string`), rather than a fixed struct per method** — JSON-RPC's
  shape varies by `.method`, and inspecting fields on demand fits that better than one
  struct big enough for every possible message.
- **A malformed JSON body is recoverable; a malformed header is not.** `Content-Length`
  framing means a body that fails to parse as JSON has still been read in full — the
  stream is exactly where the next message begins, so `Lsp.run`'s loop treats
  `error.InvalidJson` as "skip this one message, keep serving." A problem with the
  headers themselves (no usable `Content-Length` at all) leaves the reader's position no
  longer trustworthy, so that is treated as fatal instead, ending the session honestly
  rather than guessing at resynchronization.
- **LSP positions (zero-based `{line, character}` in UTF-16 code units) needed one new,
  small, allocation-free conversion** (`lspPosition`): `Source.location` gives a
  one-based line and a Unicode-*scalar* column, neither of which matches. Walking the
  target line's text with the same `unicode.decode` the rest of the compiler already
  uses, and adding 1 per scalar or 2 for anything above `0xFFFF` (a surrogate pair, via
  the pinned stdlib's own `std.unicode.utf16CodepointSequenceLength`), was enough —
  verified against a plain ASCII case, an accented BMP scalar, and an actual astral
  emoji end to end (a real `documentSymbol`/diagnostic response reported the exact
  expected UTF-16 column in each case, surrogate pair included).
- **Document symbols reuse the parser's output directly, no resolver or checker
  involved** — deliberately, since an outline should still work on a file with type
  errors, and every declaration already carries the spans needed
  (`name_span`/`Statement.span`). The member walk mirrors `Formatter.Printer`'s member
  enumeration in spirit (the same six kinds: fields, a constructor, methods, properties,
  type-functions, type-fields) but in fixed group order rather than re-sorting by source
  position, since an outline's own conventional grouping does not need to match the
  formatter's "print exactly as written" requirement.
- **Checked.** Every handler was exercised end to end by piping hand-framed JSON-RPC
  messages into `emerald lsp` and inspecting the raw framed responses (the `initialize`
  handshake; a valid and a broken document's diagnostics; `didChange` correctly
  re-checking and clearing a diagnostic; `documentSymbol` against a struct with a field,
  a constructor, and a method, an enum with a value, and a trait's property requirement;
  `formatting` on both parseable and unparseable text; a string-typed request `id`; an
  unsupported method correctly answered "method not found"; a query against a URI that
  was never opened returning an empty result rather than crashing) — the same spirit as
  this session's own piped-stdin verification of the REPL, since a full editor round-trip
  is out of scope for this slice. `Lsp.zig`'s own unit tests (wired into `zig build test`
  as `emerald-lsp`, `Repl.zig`'s `repl_module` pattern) cover the frame round-trip, a
  clean end-of-input, both UTF-16 conversion cases, and the document-symbol walk.
- **Deferred**, matching this slice's scope: hover, go to definition, find references,
  safe rename, and completion (see the milestone paragraph above for what each needs);
  `$/cancelRequest` and genuinely concurrent request handling (one message is processed
  at a time, synchronously); incremental (range-based) `didChange` sync, full-document
  sync only.
- **A real editor round-trip (via `../emerald-vscode`) found a real bug the hand-framed
  JSON-RPC testing above could not have caught: `emerald lsp` rejected the exact command
  line a real LSP client uses.** `vscode-languageclient`'s `Executable` transport
  unconditionally appends `--stdio` to the server's arguments for `TransportKind.stdio`
  (the ecosystem convention for servers that support more than one transport, even
  though this one only ever offers stdio) — so the real invocation is `emerald lsp
  --stdio`, not the bare `emerald lsp` every manual test above used. `main.zig`'s arg
  count check treated the extra argument as misuse, printed the usage text, and exited
  64, which `vscode-languageclient` reports as a cryptic `Pending response rejected
  since connection got disposed` (and, after five failures in three minutes, gives up
  restarting the server entirely) — nothing about that message points at "wrong
  argument count" without reading the actual `Server process exited with code 64` /
  usage-text lines above it in the "Emerald Language Server" output channel. Fixed by
  accepting and ignoring an optional trailing `--stdio` after `lsp`. Lesson for next
  time: a hand-framed stdio test exercises the protocol but not the real argv a client
  spawns the server with — worth checking that separately before calling an LSP slice
  done.

### REPL decisions worth knowing

- **A session is one single, always-growing "entry" file, re-run from scratch by the
  unmodified pipeline on every accepted entry — not a persistent interpreter.** Explored
  first and rejected: threading `Interpreter.run`'s heap and module scope across separate
  calls, since nothing about them survives past one call today (`defer
  interpreter.heap.deinit()` runs unconditionally), and reconciling `Checker.check`'s
  `Type.User` — compared by pointer, rebuilt fresh every call — across repeated calls
  would be a genuine correctness hazard, not just a performance one. Modeling the session
  as one growing file instead sidesteps 14.1's one-entry-file restriction entirely (there
  is only ever one file, always the entry) and gives every binding rule for free, at the
  cost of redoing the whole session's work on every entry — invisible at typing speed,
  and exactly correct rather than an approximation, since every language feature that
  exists today is observable only through `print`/`input` (no clock, filesystem, network,
  or randomness).
- **A bare expression is rejected by the parser, not the checker** — found while wiring
  the "wrap a bare expression in `print(...)`" rule, which first assumed the opposite.
  `Parser.finishExpressionStatement` enforces 5.2's "only a call" rule immediately: a
  non-call expression statement never becomes an AST node to inspect, it becomes a parse
  diagnostic, "this result is never used." A REPL entry that is exactly this one
  diagnostic, with nothing else parsed alongside it, is section 18.4's "a bare
  expression"; the entry's own literal source text is wrapped in `print(...)` and tried
  again, rather than the classifier ever inspecting an `Expression.Data` shape that the
  parser does not actually produce for this case.
- **Two different diagnostic shapes both mean "ran out of input," and only one of them is
  positioned at true end-of-file.** A closing delimiter expected somewhere other than a
  block's `}` (a call's `)`, an index's `]`, ...) is reported as `"expected ... found {s}"`
  at the lexer's one always-present, zero-width `.eof` token — structurally checkable by
  position alone. A `{ ... }` body — a block, `case`, or lambda — instead reports "this
  block/`case`/lambda is never closed" at its *opening* brace, so the reader sees which
  block is unclosed rather than only "found EOF"; each is only ever reached after its own
  parse loop breaks specifically on `.eof`, so the message text alone is exactly as
  reliable a signal here as position is for the other family. The lexer has its own,
  analogous pair: `"this block comment is never closed"` and `"this string is never
  closed"` both fire only when the scanner runs off the true end of input — except the
  string message is shared with a single-quoted or raw string illegally spanning a bare
  newline (a permanent error, since neither may span a line by grammar), told apart from
  a genuinely incomplete triple-quoted string only by the reported span's length (1 byte
  for the single-character delimiter, 3 for `"""`), not by its text.
- **The replay reader's costliest bug: pulling more from the live stream than the current
  read strictly needs strands the surplus somewhere that gets thrown away.** The first
  version forwarded whatever `limit` its caller passed straight to the live reader,
  bounded only by its own scratch buffer's capacity — large enough, in practice, to drain
  an entire waiting line (or more) from the terminal in one call, since a pipe or terminal
  buffer commonly hands over everything available at once. Those extra bytes landed in
  the `ReplayReader`'s own per-turn buffer, a stack local discarded at the end of that one
  `tryEntry` call — permanently gone from the *one shared, long-lived* reader that both
  the REPL's own prompt-reading and every entry's `input()` share for the whole session.
  Symptom: typing an `input()`-driven entry followed by ordinary code silently ate the
  following lines and ended the session at the next prompt, as if Ctrl-D had been pressed.
  The fix — request at most one byte at a time from the live reader specifically,
  regardless of what the caller's own limit allows, per the vtable's explicit invitation
  to make short reads — costs nothing in practice, since the live reader's *own* buffering
  (already relied on elsewhere, e.g. `Interpreter.evaluateInput`'s `peekGreedy`/`toss`)
  absorbs the real cost of talking to the terminal one syscall at a time, not one byte at
  a time. Replaying already-recorded bytes needed no such care, since re-serving a large
  chunk from an in-memory slice never destroys anything a later read might still want.
- **`zig build`'s module-based test discovery does not walk a root's own `@import`s the
  way plain `zig test <file>` does.** `Repl.zig`'s own tests were invisible to `zig build
  test` until they got their own module (`repl_module` in `build.zig`, mirroring
  `conformance_module`'s shape) rather than relying on `main.zig`'s `@import("Repl.zig")`
  to pull them in — confirmed by first adding a trivial test directly in `main.zig`
  (found immediately) and then one of `Repl.zig`'s (invisible, `pub` on the import made no
  difference either) before landing on the fix.
- **Checked.** Every fix above was confirmed non-vacuous by reverting it and observing the
  specific behavior break under manual interactive testing (piped stdin scripts covering
  every scenario in this slice's plan) before restoring it; `Repl.zig`'s own unit tests
  cover the completeness heuristic's every branch, including both "never closed" families
  and the single-quoted/triple-quoted string distinction, and are wired into `zig build
  test` via `repl_module`.
- **Deferred**, matching this slice's scope: an interpolation left open across a physical
  newline is a hard error rather than "keep typing," since the lexer's diagnostic for it
  does not distinguish that case from a single-line string illegally spanning a newline;
  no custom Ctrl-C handling, so the terminal's default (process exit) applies; and
  performance is O(session length) per entry (a full replay every turn), invisible at
  human typing speed and revisited only if a real session ever feels slow.

### Formatter decisions worth knowing

- **The lexer and parser are unchanged.** `Lexer.zig` still discards ordinary `#` and
  `#[ ... ]#` comments entirely, and `Parser.zig` still discards `.doc_comment` tokens
  without attaching them to the tree — both stay exactly as every other stage needs them,
  with no new field or mode added to either for the formatter's sake. Instead,
  `Formatter.collectTrivia` re-scans the byte gaps between the tokens `Lexer.tokenize`
  already produced (`.doc_comment` and `.newline` tokens included, i.e. before the
  parser's own cursor skips anything). Every such gap is provably nothing but spacing,
  blank lines, and comments — string and interpolation content always lives inside a
  token's own span, never in a gap — so a small dedicated scanner mirroring
  `Lexer.lexComment`'s recognition rules recovers them completely, as one flat,
  source-ordered list of `Trivia` (`blank_line`, `line_comment`, `block_comment`,
  `doc_comment`).
- **Blank-run counting has to see across a `.newline` token, not just within one gap.** A
  statement's own terminating newline is a real token, not part of any gap, so a blank
  line right after one sits in the *next* gap along; `collectTrivia` carries one `newlines`
  counter across both, incrementing it for a `.newline` token itself and only deciding
  whether a blank-line marker is needed once it reaches whatever comes next.
- **A blank-line marker's position needs `<=`, not `<`, in `flushTrivia`'s cursor check.**
  It is deliberately placed exactly at the next real token's own start byte, since nothing
  else is there for it to collide with; a strict `<` therefore left it just out of reach of
  the very `flushTrivia` call that should have emitted it, and it was picked up one
  statement later instead. The symptom was exact and specific: every blank line in a file
  printed one statement later than it appeared in the source. Ordinary comments never hit
  this, since their span always ends strictly before whatever token follows them.
- **The printer is one recursive-descent walk of the parsed `Ast.Program`,** sharing a
  single monotonic `trivia_cursor`. `flushTrivia(before)` consumes and emits every trivia
  item positioned before a given byte, and is called before printing each statement, type
  member, or `case` arm, in source order, so a comment or blank line is placed exactly
  once regardless of how deeply what surrounds it is nested; `printTrailingComment` is the
  one exception, consuming the *next* trivia item early, out of that order, when it sits
  on the same source line as what was just printed, so `print(score) # 14` keeps its
  comment rather than stranding it above the next statement.
- **A member's position, not its kind, decides where it prints.** `StructDeclaration`
  groups its members by kind (`fields`, `methods`, `properties`, ...), the same way
  `Program` keeps `using` apart from `statements` (14.2); both are merged back into one
  source-ordered sequence before printing, by sorting on each item's own span, exactly the
  same technique in both places.
- **Grouping parentheses are re-derived from precedence, never preserved as written.**
  Parsing erases the difference between `(a + b) * c` and any equivalent grouping once
  the tree is built, so the only sound approach is for the printer to decide fresh, from
  section 5.3's precedence and associativity, which parentheses change meaning at each
  position and add exactly those (`Printer.Level`, `printOperand`). The one narrow
  exception is `(-9223372036854775808)`: section 5.3 gives the minimum `Int` its own
  fast path in `Parser.parseUnary`, which returns straight from there without ever handing
  it to `parsePostfix`, so unlike every other literal it cannot take a `.member`, a call,
  or an index without parentheses to protect it. Found by running the formatter over
  `conformance/run/int-methods.em` and noticing `(-9223372036854775808).digits()` had
  quietly lost its parentheses and its meaning.
- **A call's argument list has no trailing comma in its grammar; a list, dictionary, or
  tuple literal's does** (`Parser.finishCall` versus `finishDictionaryLiteral`/
  `finishTupleLiteral`/`parseListLiteral`). The printer adds one only where the grammar
  accepts it. Found the same way: `conformance/run/lists.em`, reformatted, stopped
  parsing at a trailing comma the printer had added after a multi-line call's last
  argument.
- **Every number, string, and interpolation literal prints its exact source span,
  never its cooked `Ast` value.** The checked value has already had every escape resolved
  and a triple-quoted string's indentation stripped (9.1), so reprinting it would need to
  re-invent both roundtrips; copying the span instead means a written literal survives
  untouched and sidesteps the question entirely. The cost, accepted for this slice: code
  written inside `#{ ... }` is not itself reformatted, since the whole interpolated
  expression sits inside the span being copied.
- **Line breaks the author already chose are preserved, not reflowed to a width.** A user
  decision, made explicit before implementation began: this is a normalizer in the manner
  of gofmt for its first slice, not a full pretty-printing engine, and no line width is
  invented, since none is settled anywhere else in the rewrite context. Whether a call's
  arguments, or a list/dictionary/tuple literal's elements, already contain a newline
  between two of them is the one primitive this needs (`exprsSpanMultipleLines`), checked
  only in the gaps between elements so that one multi-line argument (a triple-quoted
  string, a block-bodied lambda) never forces the list around it onto multiple lines by
  itself.
- **A block-bodied lambda prints on one line when its source did.** `total += price` is
  an assignment, a statement rather than an expression, so `Ast.Expression.Lambda.Body`
  gives it the `.block` form even when written all on one line right after `=>`
  (`Parser.parseLambda`'s `brokeLine` check) — printing every `.block` body as multi-line
  would have reformatted `{ price => total += price }` into three lines on every run.
- **A trailing-block call's disambiguating parentheses have to survive in three more
  positions than a plain operand does: an `if`/`while` condition, a `for`'s iterable, and
  a `case` subject** (found in the adversarial review, chunk 7). `Parser.in_control_header`
  makes the `{` right after a call in exactly these three positions open the statement's
  own body rather than the call's trailing block (7.4), so `if items.any? { n => n > 0 } {`
  fails to parse at all — only a bracket or parenthesis beneath the header re-admits a
  trailing block underneath it. `printHeaderExpr`/`headerNeedsParens` wrap the whole header
  expression in parentheses whenever a `Call.trailing` sits anywhere in it without first
  crossing one, which covers a bare `items.any? { ... }` and an arbitrarily nested one alike
  (`items.filter { ... }.count > 0`) with the same, single check. Confirmed non-vacuous by
  reformatting `if (items.any? { n => n > 2 }) { ... }` with the fix disabled: the result
  failed to parse on a second formatting pass, which is exactly the bug this closes —
  `conformance/format/control-header-trailing-block.em` guards both the bare and the
  nested case.
- **Checked.** Every fix above was confirmed non-vacuous by reverting it and watching a
  specific conformance case fail, then restoring it. Beyond `conformance/format/`: every
  file under `examples/` is a round-trip fixture (formatting it must produce the file
  unchanged); the whole `conformance/` corpus (`run/`, `runtime-errors/`, `diagnostics/`,
  `lexical/`, and their own `format/`, 407 files) formats without crashing and is
  idempotent; and every `conformance/run/` program prints identically before and after
  being formatted.
- **Deferred**, matching the user's line-wrapping decision and this slice's chosen scope:
  a full width-based reflow engine; reformatting code written inside string
  interpolation; wrapping a parameter list or a `case` arm's alternatives that spans more
  than one line (every example in the language keeps both short enough that this has not
  come up, and joining a wrapped alternatives list onto one line, as the review found `case
  f(1, 2, 3) { when 6,\n    7 { ... } }` does, is a reformatting rather than a correctness
  problem); the REPL and LSP, queued to follow the formatter per the roadmap.

### Enum and `case` decisions worth knowing

- **An enum is a struct declaration with `enumeration` set.** `Parser.parseEnumValues` turns
  each value into a `const` type-level field (`TypeField.enum_value` is its position) whose
  initializer is an `Ast.Expression.enum_value` node, so `Direction.north`, namespaces,
  `using`, lazy type setup, and `const` all come from section 10.4's machinery. The resolver
  hoists enum values before the enum's other members (`enum_values`, `enum_listings` for
  help text); the checker's `MemberKind.enum_value` words duplicates.
- **At runtime** an enum value is a fieldless `Heap.StructValue` with `variant` set, built
  once when its type is set up. `Value.StructType.values` names the variants for display,
  and equality and hashing include `variant`. Nothing copies one, since it has no fields to
  change; `uniqueStruct` copies `variant` anyway.
- **`case` is `Ast.Case`,** held by pointer in `Statement.Data.case_statement` and
  `Expression.Data.case_expression`. `Parser.parseCase` enforces one arm form and recovers by
  skipping to the `case`'s `}`. `Checker.checkCase` checks arms as branches with
  `snapshot`/`restore`/`intersect`, narrowing subjectless conditions like an `if` chain;
  `caseCoverage` and `knownAlternative` decide completeness and duplicates, and
  `exhaustive_cases` lets `stmtCompletes` treat a complete statement `case` as running an
  arm. The completion helpers (`blockCompletes` and friends) became checker methods for
  that. `typeOfCase` records the result type in `literal_types` so `Interpreter` widens.
- **Lexer.** A `{` now saves `group_depth` and starts at zero, and its `}` restores it
  (`brace_depths`), so a `case` or block inside parentheses keeps its newlines.
- **The recursion budget bit again.** One more call site in `Interpreter.evaluate` broke
  "a body nested 250 deep still supports 1,000 calls"; `evaluateByNode` now shares one call
  site for `type_test`, `lambda`, `enum_value`, and `case_expression`. Add new node-only
  expressions there.
- **Checked.** Eleven mechanisms were disabled one at a time, each failing a case: variant
  equality, statement-case completeness, enum coverage, duplicate alternatives, subjectless
  narrowing, value widening, the lexer's brace reset, the resolver's enum hoisting, parser
  recovery, and rejecting construction. Hashing the variant is not observable, because
  equality still separates colliding keys, and lazy evaluation of alternatives is pinned
  only by `run/case`'s trace output.
- **Deferred.** The warning for a nonexhaustive enum statement `case` (no severities yet);
  narrowing a subject by `when nothing`; range, destructuring, and class matching (6.3).

### `Self` and operator decisions worth knowing

- **The prelude has Emerald source now.** `src/prelude.em` declares the five operator
  traits and is embedded by `emerald.zig`, which appends it to the project's files after
  the encoding checks, so every stage treats it as one more non-entry file and the
  program's files keep their indices. Its namespace is `Resolver.prelude_namespace`
  (`emerald`), which no directory can produce; `offerKey` offers its names bare to every
  file but lets a file's own name replace them, and `collectNamespaces` and `noteElsewhere`
  skip it. `analyze` asserts no diagnostic points into it.
- **`Self` is `Type.opaque_self`** on a `struct_value` whose `user` is the trait. Only a
  `Self` is assignable to `Self`; a `Self` is assignable to its trait and what the trait
  builds on. `Checker.written_self` gives `Self` its meaning while `signatureFor` resolves a
  method's or type-level function's parameter and result types (`selfInSignatureOf`), and a
  trait's method body gets `self` as `Self` (`ownSelf`).
- **Substitution happens where a member is reached.** `signatureOn(signature, receiver)`
  replaces `Self` with the receiver's `Self`, the adopting class (`adopterOf`: the first
  along the base chain to conform), or the trait for a trait-typed receiver; `takesSelf`
  rejects a `Self` parameter through a trait-typed value. It is used by method calls, method
  values, operators, `checkOverride`, and `checkTraits`. `Trait.method(value)` rejects a
  signature mentioning `Self` rather than substituting from the first argument.
- **Operators.** `Ast.BinaryOperator.contract` and `OperatorContract.ordered` name the trait
  and method. `Checker.typeOfOperatorCall` runs for a non-optional user-type left operand
  from `typeOfBinary`, compound assignment (through `arithmetic`), and `typeOfComparison`,
  checking adoption, `Self`, the right operand, change, construction (`reportOverridable`),
  and captures. The resolver's `noteMemberCall` records the method for binary, comparison,
  and compound expressions, for 7.1's capture check. At runtime `Interpreter.callOperator`
  looks the method up in the left object's method table, which every adopting type has,
  applying the build-depth guard, and invokes it with the operands retained.
- **Checked.** Thirteen mechanisms were disabled one at a time, each failing a case:
  prelude shadowing, `Self` in override checks, `adopterOf`, `takesSelf`, `self` as `Self` in
  trait bodies, `Self == Self`, the three capture recordings, the change rule, the runtime
  build guard, the construction rule, and resolving a requirement property's type.
- **Found while testing.** A trait's requirement property never had its type resolved, so
  `const smaller: Self` or a misspelled type there went unreported; the final pass now
  resolves it. `2 * vector` had said one operand "may be absent"; that help now needs an
  actual optional.

### Trait decisions worth knowing

- **A trait is a struct declaration with `trait` set,** as a class is. The parser's
  `in_trait` makes a body-less method a requirement (`abstract_span` is its name) and turns
  `const name: String` into a property whose accessors have no body, so every later pass
  treats a requirement as an abstract property. `with` lists fill `StructDeclaration.traits`
  and `Type.User.traits`; `Type.User.conformsTo` is what assignability uses.
- **Checker.** `resolveTraits` and `breakTraitCycle` run beside the base class passes;
  `traitClosure` lists every trait a type has. `memberKey` looks through traits after the
  class chain, never finding a trait's private member. `checkInheritedName` accepts a field
  or property for a trait property and requires `@override` on a method; `checkTraits`
  judges supply and conflicts once per name, where introduced. `methodChanges` treats a
  requirement as changing when a struct supplying it changes, and `capturesOf` follows a
  trait member to every type's version. `typeOfTraitDefaultCall` checks `Trait.method(value)`,
  recorded in `Checked.trait_calls`.
- **Runtime.** A trait has no descriptor, only its functions and `Interpreter.trait_infos`.
  `inherit` builds a method table for any type adopting a trait, filling in defaults and
  default properties that nothing else supplies, and `StructType.traits` lists the closure
  for `is`. `dispatch` never replaces a private method. A changing method called through a
  trait peeks at its receiver to pick the version before taking it (`callStructMethod`).
- **Checked.** Six mechanisms were disabled one at a time, each failing a case: the changing
  path's dispatch, requirement change inference, the private dispatch guard, `is` for traits,
  missing requirements, and the capture check through traits. Filling defaults into the table
  is not independently observable, because dispatch falls back to the key the checker chose;
  it keeps the build-depth guard exact.

### Type test decisions worth knowing

- **`is` is `Ast.Expression.TypeTest`,** parsed by `Parser.finishTypeTest` after the first
  operand of a comparison. `Checked.type_tests` records the value's static type and the tested
  type; `Interpreter.valueIs` needs only the object's class (`Value.StructType.isOrExtends`,
  through the new `StructType.base`) and, for a tuple, each position's.
- **Narrowing** is a new arm of `Checker.narrow`, using `narrowsTo`. `typeOfLogical` now
  narrows before checking the right side and puts the types back with `restoreTypes`, which
  also gave optionals `x != nothing and x > 3`.
- **`type_name`** is caught at the top of `typeOfMember`, before optional presence and
  construction readiness, and recorded in `Checked.type_names`; `writeTypeName` spells the
  static type, putting each object's class in. A member named `type_name` and an assignment
  to it are rejected.
- **A member only a subclass has** gets `subclassMemberHelp`, which names the first-declared
  subclass with it and says how `is` reaches it, or why a name cannot be narrowed.
- **The recursion budget is tight.** Passing the `TypeTest` by value to its helper grew
  `evaluate`'s Debug frame enough to fail the 250-deep, 1,000-call test; its helpers take the
  expression instead.
- **Checked.** Five mechanisms were disabled one at a time, each failing a case: walking base
  classes in a test, narrowing by a test, narrowing in `and`/`or`, an object's class in
  `type_name`, and the subclass correction.

### Inheritance decisions worth knowing

- **Syntax.** `Ast.StructDeclaration.base` and `abstract_span`, and `override_span` and
  `abstract_span` on methods and properties. The parser reads annotations
  (`parseAnnotations`, with spelling suggestions and `@test` reported as not available) and
  says where each cannot go; an `@abstract` method leaves out its body. `super` parses as the
  name `super`, only before `.` or `(`, and `Parser.has_base` says whether it means anything.
- **Resolver.** `Facts.bases` maps a class to its base class's key, recorded once every
  file's names are known, and the base class is recorded as a call of the subclass for the
  capture check. `super` is never looked up.
- **Checker.** `resolveBase` and `breakBaseCycle` run before fields; `ensureStructChecked`
  resolves a base class's fields first, and `Type.User.fields` holds every field, base
  class's first, with `inherited` counting them and `Field.owner` naming the declaring type
  for privacy. `memberKey` finds the nearest declaration of a method or getter and
  `memberOwner` the declaring type; every member lookup goes through them.
  `checkInheritedName` judges names against the base classes and `checkInheritance` judges
  overrides, abstract methods, and a subclass without a constructor.
  `declarationWithDefaults` gives an override the defaults of what it replaces. Construction
  records `Constructing.super_call`; inherited fields are unset until that call is checked,
  or set from the start without one. `reportOverridable` enforces 10.2's rule for calls,
  reads, sets, and captures through `self`. `capturesOf` follows a class method to every
  override of it. `Checked.super_members` records `super.name` property reads (by member
  expression, getter key) and assignments (by value, setter key).
- **Runtime.** `Value.StructType.depth` and `methods` (name to the version this class runs,
  with its class's depth), and inherited properties replaced in place, are filled in by
  `Interpreter.inherit`. `dispatch` picks the version unless the receiver is `super`, and
  `propertyOf` does the same for properties. `Interpreter.overrides` maps an override to the
  declaration whose defaults it uses, with `Callable.defaults_file`. A subclass object is
  built by `buildPart`, base class first; a constructor of a class that extends another is
  invoked with `Callable.construct`, and `buildBaseFirst` runs its `super(...)` or the
  zero-argument call, then its field defaults. `Heap.StructValue.built` is the deepest class
  whose part has begun, and a version declared deeper raises (`raiseUnbuilt`).
- **Checked.** Eight mechanisms were disabled one at a time, each failing a case: dispatch,
  override defaults, the defaults' file, the build-depth guard, following overrides in the
  capture check, `super` property reads, privacy of a base class's fields in a subclass's
  constructor, and setting the build depth for a generated constructor.

### Class decisions worth knowing

- **A class is a struct declaration with `class` set.** `Ast.StructDeclaration.class`,
  `Type.User.class`, and `Value.StructType.class` carry it, so every member, the
  constructor rules, privacy, type-level members, and method values are shared code. The
  parser's `in_class` makes a member's `self` context `class_member`, which a block or nested
  function keeps. `extends` and `with` are parsed far enough to say they are not available
  (and that a struct never extends).
- **The runtime never copies an object** (`Heap.uniqueStruct` returns a class instance as
  it is) and compares objects by pointer (`Value.equals`). `Value.write` keeps a thread-local
  stack of the objects being written and prints `Name(...)` for one met again.
- **Changes through an object start from the object.** `objectOnPath` finds the deepest
  object on a runtime path and the steps after it. Assignment (`storeInObject`), a changing
  struct method (`callStructMethod`), and a changing list or dictionary method
  (`callChangingMethod`) work from there, so no binding is taken while they run. A setter at
  the end of the path runs on what it reaches; for a struct inside an object the setter or
  changing method takes the object's field out while it runs (`changeInObject`, with
  `taken_fields` checked where a field is read or written), a rule the object model review
  added in place of storing a copy back. A temporary root is evaluated
  (`temporaryRoot`), which is how `make().items.append(x)` works.
- **The checker's `const` rule stops at an object.** `resolvePlace` now returns
  `Place.Typed` with `reference` (an object was crossed) and `frozen` (the first `const`
  field after the last object); `requireChangeablePath` judges both for a receiver, and
  `checkPlaceAssignment` tracks the same two while it walks. A temporary's type is worked out
  again with its diagnostics discarded, to see whether the path through it reaches an object.
  `methodChanges` is false for any class method, and `selfPathType` and `stepsReachObject`
  stop at an object, so a struct method that changes only an object it holds is not
  changing.
- **Classes are not dictionary keys** (`Type.eligibleKey`), and a struct holding one is not
  either.
- **Checked.** Six mechanisms were disabled one at a time, each failing a class case:
  never copying objects, identity, the `const` boundary, class methods never changing,
  stopping change inference at an object, and assignment from the object (whose case is a
  setter that reads the object's binding while it runs). 200,000 iterations building object
  cycles stay at 4.1 MB.

### Nested function decisions worth knowing

- **Visibility is a lambda's (7.1, recorded in section 22).** A nested function sees the
  variables declared above it. That is also what a top-level function sees of the module,
  so an alternative where it saw its whole block was rejected: it would have been the one
  function that could read below itself.
- **Keys and hoisting.** A nested function is known as `name@file:start`
  (`Resolver.nestedKey`), found from its declaration through `Facts.nested_keys` by `Site`,
  so no pass allocates a key while running. Each pass hoists the names a block declares
  before walking it: the resolver as a `.function` binding carrying `function_key`, the
  checker as an `is_function` binding with the same key, and the interpreter as a closure
  over the scopes in force at the start of the block (`hoistNestedFunctions` in
  `executeAll`). The closure is `.named`, so `closureCallable` now passes a named closure's
  captured scopes along; a program function's are empty. `callValue` binds a named closure's
  arguments through `evaluateBoundParameters`, which is what gives nested functions defaults
  and named arguments.
- **The body is checked against the scopes around its declaration**
  (`checkNestedBody`, through `checkBodyWithSelfIn`), with every variable there counted as
  assigned and nothing narrowed, since it can run at any time. `Checker.nested` records how
  many scopes that is; the same scope objects are still at those positions wherever the
  function can be named. A use above the declaration can therefore infer its return type on
  the spot, exactly as a top-level call does.
- **Uses are judged in two halves.** The resolver records, for each nested function, the
  locals of enclosing functions it reads or assigns (`Capture`, owned by the function that
  declared them) and every use, then walks the call graph from each use once all bodies are
  walked (`judgeNestedUses`). A capture owned by the function the use is in must be declared
  above the use, or the resolver reports it; the ones it reads go to `Facts.nested_uses`,
  and `checkNestedUse` reports any not certainly assigned there. Captures owned by another
  function are left to the uses inside that function. The walk follows only nested
  functions, and never the function the use is in: calling that one, or any function that
  is not nested, starts a frame of its own (review fix, guarded by the two `countdown`
  programs in `run/nested-functions`). A destructuring assignment records what it writes,
  as a plain one does; it once crashed the interpreter.
- **A use inside a lambda, and taking the function as a value, are judged where written.**
  That can reject a program that would have run, as in `const f2 = later` before the
  variable `later` reads is assigned. Kept deliberately (section 22): 7.1 says hoisting
  never permits reading an uninitialized captured variable, and a write through an
  undeclared variable would crash rather than raise. Top-level functions do not yet check
  these two forms at all and catch the read at runtime instead ("`n` is not assigned
  yet"); bringing them in line is open.
- **Assignments in a nested function count as assignments in a lambda** for narrowing (4.5),
  through `lambda_depth`.
- **A call by a bare name finds its binding the way a read does** (`find`), so a local hides
  a module-level name even when `using` gave that name its own key. The checker once looked
  the key up first and checked `shout("hi")` against an imported `shout` while the
  interpreter ran the local block (review chunk 2; `run/local-hides-imported-function`).
- **Equality is a closure's identity.** A `.named` closure that captured scopes is a nested
  function, and `Value.sameFunction` compares it like a lambda; only top-level functions
  compare by name (review chunk 3).
- **A nested function belongs to the code it is written in** for the resolver's
  `enclosingType`, through `FunctionScope.enclosing`, so a bare member name inside one in a
  method still gets the `self` correction (review chunk 4; `diagnostics/member-without-self`).
- **A duplicate is reported at whichever is written second.** A nested function is hoisted,
  so `var name` above `func name()` would otherwise be reported at the `var`.
- **A variable declared below a nested function** is reported as exactly that. A block that
  declares nested functions pushes its own variables onto `Resolver.block_locals` while it is
  walked, and `reportUndefined` looks there first (review chunk 6).

### Nested pattern decisions worth knowing

- **`Ast.Pattern` has `positions` and `names`.** `positions` is the structure, each a name or
  a nested pattern; `names` is every name bound, flattened, which is all the resolver and the
  name-only loops in the checker needed, so they are unchanged. `bindPattern`,
  `assignPattern`, and `unpackInto` recurse through `positions`. A destructuring assignment
  builds its pattern from the tuple literal it parsed as (`patternOfTuple`).
- **Mismatch messages** count positions rather than names once a pattern nests, and a nested
  position that is not a tuple is reported at that position.
- **`startsPattern` accepts a trailing comma**, as `parsePattern` always did: `const (a, b,)`
  was read as a declaration missing its name (review chunk 5).
- **A standalone lambda that unpacks a tuple** says it cannot tell what tuple it unpacks and
  shows where to write the type, rather than "`` needs a type": a pattern parameter has no
  name, and there is no syntax for annotating one.

### Method value decisions worth knowing

- **A captured method is a closure with a receiver (7.5).** `Heap.Closure.Function` gained
  `.method` (the method key), and `Closure.receiver` holds the copy, released with the
  closure and counted, marked, and dropped by the collector like a field. The checker records
  the member expression in `method_calls` (the map calls already use) and gives it the
  method's function type; `evaluateProperty` builds the closure when that map has it.
- **Every call through a value goes through `invokeClosure`.** A reading method gets a
  retained receiver as `self`. A changing one takes the receiver out of the closure, sets
  `running`, and leaves `self_out` behind as the new receiver, so the copy stays unique and
  `self.items.append` does not copy the list on every call. Calling the same closure again
  while `running` raises "already changing its captured copy"
  (`runtime-errors/captured-method-called-again`). `callHigherOrder` works out the closure's
  `Callable` once and passes it in, so `each` does not repeat that per element.
- **Readiness in a constructor is the call rule.** Capturing `self.method` waits for every
  field, and a field or parameter default cannot capture one
  (`diagnostics/method-value-before-ready`). Privacy is checked before either.
- **Capture analysis needed nothing new.** The resolver already records reading
  `value.name` as a possible call of every member by that name, which covers calling the
  captured value later.
- **Display and equality.** A captured method prints as `<func name>`, and two are equal only
  when they are the same closure, like lambdas.
- **Not in this slice: built-in methods.** `numbers.append` without parentheses still says it
  needs parentheses. 7.4's rule that every method is capturable, including the expected-type
  rule for `numbers.map`, is still to do.
- **Checked.** The heap test "a captured method keeps its receiver alive" fails without
  either the mark or the internal count of the receiver. A 200,000-iteration program that
  builds cycles through captured receivers stays at 3.5 MB, against 460 MB without the count.
  Timing a closure-heavy program against the previous commit moved within code-layout noise
  (a closure-free loop moved further, in the other direction).

### Privacy decisions worth knowing

- **The boundary is the type's braces (10.5).** `Checker.type_spans` records each struct's
  declaration span; `insideType` asks whether an access is in that span and in the file
  `facts.owner` records for the type. Lambdas, field defaults, and type-level field values
  are checked with `self.file` set to where they are written, so they count as inside
  without extra state. Another value of the same type is reachable (`other._count`).
- **One helper, called from every way to reach a member.** `reportPrivate` (instance members,
  by type key and name) and `reportPrivateTypeMember` (type-level members, by key) are called
  from `typeOfMember`, `typeOfStructMethodCall`, the field steps of `checkPlaceAssignment`,
  `typeOfQualified`, `typeOfCall`, and both assignment paths for a type-level field. An
  instance check runs only when the name is a real instance member, so a missing `_name`
  still says "has no field", and `value._type_member` still says to go through the type.
  `resolvePlace` returns `.reported` without a message for a private field, because the
  receiver's `typeOf` has already reported it.
- **The generated constructor keeps every field as a parameter (user decision).** Called from
  outside the type, a private field with no default makes the call an error at the callee
  ("cannot be built here"), and giving a private field a value is reported at that argument
  (at its name when passed by name), through `Parameters.private_to`. Inside the type,
  `Pair(5, 6)` sets private fields as usual.
- **Privacy outranks "reach it the other way".** From outside the type, `Counter._count` (an
  instance member through the type) and `c._made` (a type-level one through a value) report
  that the member is private, since the other path is private too: the resolver decides
  inside from `enclosingType`, the checker from `insideType` (review chunk 4;
  `diagnostics/private-member-through-type`).
- **No runtime part.** Privacy is purely a checker rule, so the interpreter is unchanged.
  Display and equality include private fields.
- **Found while writing the example.** A `##` documentation comment before a type-level
  function made the parser miss its type receiver, because `startsTypeMember` indexed raw
  tokens. It now steps over documentation comments first; `run/private-members` covers it.

### Type-level member decisions worth knowing

- **A type-level member is a module-level binding under its method key.** The resolver
  hoists `func Vector2.origin()` and `var Player.count` into the module scope as
  `Vector2::origin` and `Player::count`, and `qualify` recognizes a type's name followed by
  one member (or `Shapes.Circle.unit` through a namespace) exactly as it recognizes
  `Shapes.area`. Reads, calls, function values, captures, and stack traces then go through
  the paths qualified names already had; nothing about calling a type-level function is new.
  `Resolver.displayKey` turns a key back into what the reader wrote for diagnostics.
- **Declared inside the type, one name space.** The parser accepts `func T.name` and
  `var T.name = value` only inside `struct T`, noting a mismatched type name and rejecting
  one written outside. Type-level members join the checker's single source-ordered
  member-name pass. Both are recorded in section 22.
- **Assignment is rewritten, not special-cased.** `Player.count += 1` parses as the name
  `Player` with a field step. The resolver records the site in `Facts.type_assignments` and
  adds `Player.count` to that file's `module_keys`, so the checker and interpreter rewrite the
  statement to the one-name assignment `Player.count` and every existing assignment path,
  message, and `const` check applies unchanged. No bare name contains a dot, so the added key
  shadows nothing.
- **In-place change works through a type-level field.** `resolvePlace`,
  `requireMutableReceiver`, and `requireChangeable` accept a qualified root when it is a
  type-level field, and `evaluateReceiverPath` stops at one (`rootName`), so
  `Registry.names.append(x)`, `Board.cursor.shift()`, and the changing-method exclusivity
  guard all work. Changing through an ordinary namespace-qualified binding is still
  rejected, as before.
- **Types are inferred on first need.** An annotated field's type is resolved after struct
  metadata; an unannotated one is inferred by `settleTypeField` when first read, checked in a
  module view like a function body. Re-entering a field while it is inferred reports "needs a
  type"; re-entering a function while its return type is inferred (the `inferring` set)
  reports "needs an explicit return type", since the call graph has already ruled out plain
  recursion and only a field's value can close the loop. `find` returns the module scope's
  own binding for a type-level field, because a function body's copy of the module scope can
  predate the inference; `diagnostics/type-field-type-mismatch` fails without that.
- **No narrowing.** Assigning a present value to an optional type-level field does not
  narrow it, and reads use its declared type: it is one shared binding, and narrowing the
  module scope's entry would have leaked the proof everywhere. `run/type-level-members`
  fails without the guard. `find` also resets a type-level field's `type` to its declared
  type, because restoring the flow state after a block can put back a type saved before the
  field was inferred inside it; without that, a compound assignment after the block went
  unchecked (`diagnostics/type-field-compound-after-block`).
- **Setup is lazy, per type.** `Interpreter.reach` sends a type-level key to `setUpType`
  instead of its file, and constructing a type sets it up after its file. Setup runs the
  field values in order in the type's file, in a stack frame named "the type-level fields of
  `Config`". While it runs, calling a type-level function or constructing the type is fine;
  reading a field it has not reached raises the cycle error
  (`runtime-errors/type-setup-cycle`).
- **Section 7.1 through setup.** Field values are recorded under `Resolver.typeSetupKey`
  (`Player::`). Constructing the type and calling a type-level function have call edges to
  it, a function reaching any type-level member records one, and a top-level read or
  assignment of a field checks it directly. `isRecursive` ignores setup edges, which would
  otherwise make `func V.origin() { return V(0) }` look recursive whenever a field's value
  calls it.
- **Taking a type-level function as a value also sets up its type.** The checker applies the
  setup capture check to `const make = Banner.make`, not the function body's captures; the
  body has not run, but reaching the member already has. `diagnostics/type-function-value-capture`
  covers the distinction.
- **Assignments find their binding again after the right side.** An assignment reaches its
  type-level destination before evaluating the value, but evaluating that value can set up
  another type and grow the module table. The interpreter finds the binding again when the
  module table's count changed while the value was evaluated; nothing is removed from that
  table, so an unchanged count means the pointer is still good, and an ordinary assignment
  pays for one lookup (always looking twice made a 3,000,000-assignment loop 28% slower).
  `run/type-field-assignment-during-setup` forces the growth and guards the fix.
- **Qualified-expression capacity follows the project limit.** A type-level reference may
  contain all `Project.max_depth` namespace segments plus the type and member. The resolver's
  fixed buffer is sized from that bound; `run/type-level-members-deep-project` covers a chain
  longer than the old independent limit of eight segments.

### Defaults and named-argument decisions worth knowing

- **Why they arrived together, and with field defaults.** 10.2's "an explicitly supplied
  generated-constructor argument replaces that field's default" needs a way to supply a
  field after a defaulted one, and 7.3's named arguments are that way. Doing field defaults
  alone would have meant inventing a positional-only rule 7.3 does not have.
- **Matching lives in one place, `src/arguments.zig`.** `bind` fills parameters from
  positional arguments and names and reports the first problem; the checker reports it,
  and the interpreter repeats the same matching on accepted calls (asserting it succeeds),
  so the two cannot disagree. A call with no names and one argument per parameter
  (`isPlain`) skips it entirely, which keeps ordinary calls as cheap as before.
- **One argument check for every call by name.** `checkArguments` now takes a `Parameters`
  view, built from a function's, method's, or custom constructor's declaration, or from a
  struct's fields for its generated constructor. That retired the generated constructor's
  own copy (formerly one of the open review findings); `typeOfValueCall` still has its own, since a
  function value has no names or defaults. Old arity wording is kept when nothing is named
  and nothing has a default, so existing diagnostics did not change.
- **A trailing block fills the final parameter** (`Ast.Expression.Call.trailing`, handled in
  `arguments.bind`), so it may follow named arguments, and a final function parameter may
  follow defaulted ones. Naming the final parameter inside the parentheses as well reports
  `trailing_duplicate`. Found in chunk 5 of the review, with `run/trailing-block-after-named-arguments`
  and `diagnostics/trailing-block-arguments` guarding it.
- **A rejected named argument ends that call's checking.** On a built-in method, `print`,
  `input`, or a function value, `rejectNames` now reports once and the rest of the call is
  only type-walked, instead of adding an arity or type mismatch computed from positions that
  mean nothing (`diagnostics/named-argument-unsupported`).
- **Constructor parameter defaults may read `self`.** The parser allows it, and
  `Checker.in_parameter_default` gives readiness errors inside one default-specific wording,
  since "set `self.x` first" is advice a default cannot take.
- **Defaults are evaluated in the callee.** `Callable.omitted` marks parameters left to
  their defaults; `invoke` binds the explicit ones, switches to the callee's file and frame,
  then evaluates each omitted default in parameter order, so a default sees the parameters
  before it. `run/defaults-and-named-arguments` checks 7.3's evaluation order directly.
- **"Not itself or later parameters" is a resolver rule.** Every parameter enters scope as
  `later_parameter` and becomes readable once its own default has been walked, so
  `func f(a: Int = b, b: Int = 1)` is reported rather than quietly reading a module `b`.
- **Field defaults reuse constructor readiness.** Each default is checked as its own part of
  construction (`Constructing.part = .default_of`), with exactly the fields set that are set
  when it runs: under the generated constructor every earlier field, under a custom
  constructor only earlier defaulted ones. Reads, `self` as a whole, and method and property
  calls get default-specific wording (`reportInDefault`). A custom constructor's body starts
  with defaulted fields already set.
- **At runtime** a generated constructor places explicit arguments, then
  `runFieldDefaults` runs the missing defaults in a frame of their own, named "the field
  defaults of `Share`" in a stack trace, with `self` bound to the value being built. A custom
  constructor runs every default there before its body. Confirmed non-vacuous: running
  replaced defaults too fails `run/struct-field-defaults`.

### Property decisions worth knowing

- **An accessor is a method the parser writes.** `const area: Float { ... }` becomes a
  getter declaration with no parameters returning `Float`; `var diameter` also gets a setter
  taking `value: Float`. They are keyed `Circle::diameter` and `Circle::diameter=`
  (`Resolver.setterKey`), so the resolver, checker, and interpreter treat them as methods:
  inference, `ensureBodyChecked`, all-paths-return, captures, `self`, and `methodChanges`
  are all reused. Only reaching them is new.
- **Reads.** `typeOfMember` checks fields, then `propertyOf`. The runtime descriptor
  (`Value.StructType.properties`) carries each property's accessor keys, so
  `evaluateProperty` falls back from `fieldPosition`, now optional, to `readProperty` with no
  allocation per read.
- **Writes.** A property may only be the last step of an assignment path. Anywhere earlier,
  and as the receiver of a changing method (`resolvePlace`), it gets 10.3's "nested mutation
  through a computed value is rejected". A `const` property is read-only. `storeElement`
  hands the final step to `storeProperty`, which takes the receiver out of its slot for the
  setter exactly as `callStructMethod` does. A compound assignment runs the getter once in
  `elementValue` and the setter once in `storeElement`.
- **`assignElement` now takes its root out of the binding while it stores.** A setter runs
  user code, which could otherwise see the half-stored value, and `Binding.changing` makes
  that a runtime error naming the property (`runtime-errors/setter-receiver-in-use`,
  confirmed to fail without it). The binding is also found again after the right side is
  evaluated. Before, a pointer into the module scope was held across evaluating the right
  side, which can initialize another file and grow that scope: a latent use-after-move,
  never observed, now gone.
- **A getter may not change `self`** (recorded in 10.3 and section 22). Reading a property
  of a `const` would otherwise be an error, and `methodChanges` already answers the question.
- **Member names share one space**, checked in one pass over fields, properties, and
  methods in source order, so the later declaration is the one reported.
- **Only registered accessors are body-checked.** When a writable property loses a
  source-ordered name clash, neither its getter nor setter is registered as a declaration;
  the later accessor pass checks each key exists before asking for its body. Without the
  setter check, a method/property clash or a read-only/writable duplicate could panic in
  `signatureFor` after reporting the intended clash. Covered by
  `diagnostics/writable-property-method-clash`.
- **Parser recovery.** A `var` property's `get` and `set` blocks may come in either order;
  a missing block, a repeated one, or blocks inside a `const` property are reported without
  failing the statement, since failing it inside a struct body reported every following `}`
  as stray. `get` and `set` stay ordinary identifiers (`startsAccessor`).

### Method decisions worth knowing

- **Scope.** `func` inside a struct body, `self` inside it, calls as `value.method(args)`,
  return-type inference exactly as for functions, and section 4.3's inferred mutation.
  Still rejected: `self` inside a block (in methods, as in constructors). Method values,
  privacy, and type-level members arrived in later slices, recorded in their own sections.
- **A method is a function under a key of its own.** `Board::record` (`Resolver.methodKey`;
  `::` appears in no name, path, or other key). The checker keeps it in `declarations`
  beside functions and the interpreter in `functions`, so `signatureFor`, inference,
  `ensureBodyChecked`, `namedCallable`, and `invoke` all work unchanged; the only difference
  is that `receivers` has the key, which puts `self` in the body's scope.
- **Which method a call reaches is decided once, by the checker.** `method_calls` maps the
  callee expression to the method key, and the interpreter consults it before any
  collection-method dispatch, so a struct's own `append` or `each` is never mistaken for a
  list's. This is the same pattern as `Facts.qualified`.
- **Mutation is inferred from text plus field types (`methodChanges`).** A method changes
  `self` when its body assigns into `self`, calls a changing collection method on a path
  that starts at `self`, or calls a method on such a path that changes it. `selfPathType`
  follows the path through field and element types, so the answer exists before any body is
  checked and no call site waits on inference. Cycles of methods calling each other are
  handled by caching only settled answers: `true` always, `false` only when nothing else is
  in progress. A call to a changing method goes through the existing
  `requireMutableReceiver`, so `const`, parameters, loop variables, temporaries, and `const`
  fields on the way all get the corrections lists already had.
- **Capture analysis cannot know a method call's type, so it over-approximates.** The
  resolver records `value.area()` as a call to every method named `area` in the program
  (`methods_named`). That can only report more, never less, and matches the capture check's
  existing conservatism. A direct top-level method call is checked against its exact key.
- **A changing method takes its receiver out of its place (`callStructMethod`).** Sharing it
  would make `self.items.append(x)` copy the list on every call; 200,000 such calls now take
  0.10 s in ReleaseSafe. The root binding's value is moved into a local, the path is made
  unique with `containerSlot`, the receiver is moved out of its slot into `self`, and
  `Callable.self_out` receives what `self` holds at the end, which goes back into the slot.
  The slot pointer stays valid because the root is owned by the call alone. Meanwhile the
  binding is marked `Heap.Binding.changing`, and reading, assigning, or changing it through
  anything else raises "`meter` is being changed by `advance`" (recorded in 4.3 and section
  22; guarded by `runtime-errors/method-receiver-in-use`). Constructors now use the same
  `self_value`/`self_out` pair.
- **The take-out happens inside `invoke`, after defaults.** Section 7.3 counts defaults as
  arguments, so `callStructMethod` passes a `Take` describing the place and `invoke` calls
  `takeReceiver` once the defaults have run. `takeReceiver` swaps the caller's scopes, file,
  and stack frame back in while it finds the place, so an index out of range still reads as
  the caller's error. When a default is omitted, the defaults see a retained copy of the
  receiver as `self`, which the taken receiver replaces; the checker rejects a default that
  would change `self`, so the copy can never diverge. Guarded by
  `run/changing-method-arguments` and `diagnostics/default-changes-self`. The same case pins
  the receiver timing recorded in section 22: an argument that replaces the variable is seen
  by a changing call and not by a reading one.
- **A taken binding is not an unset one.** While a file or type is still being set up, the
  cycle check in `reach` and `setUpType` treats a binding with no value as not reached yet;
  it now also lets a taken binding through, so reaching one raises "being changed" rather
  than a misleading setup cycle (`runtime-errors/receiver-in-use-during-*-setup`).
- **Both runtime mechanisms were confirmed non-vacuous.** Treating every method as
  read-only fails `run/struct-methods`; removing the `changing` guard fails
  `runtime-errors/method-receiver-in-use`.

### Constructor decisions worth knowing

- **Scope.** One custom constructor per struct, `self.field = ...`, bare `return`, and every
  check 10.2 states about readiness. `super(...)` needs classes. `self(...)` is deferred
  with overloading (user decision): 10.2 described it delegating to "another constructor of
  the same type" while allowing only one, so it only means something once overloaded
  constructors exist. Recorded in 10.2, section 21, section 24's waiting list, and
  section 22.
- **Readiness is definite assignment, field by field.** Inside a constructor the checker
  puts one hidden binding per field into the constructor's own scope (`.x`, a spelling no
  name or key can have) recording whether that field is certainly set. Branches, loops,
  `break`, and early `return` already merge bindings correctly, so they merge readiness with
  no code of their own. `self.x` needs `.x`; `self` as a whole needs all of them; the end of
  a body that can complete, and every bare `return`, need all of them.
- **A `const` field is set exactly once, which needs the opposite question.** "May already
  be set here" is not "not certainly set" — after `if c { self.x = 1 }` the field is neither.
  A second hidden binding per field (`!x`) records "certainly still unset", which merges by
  intersection exactly as the first does. Loops restore state rather than merging it, which
  would be wrong for this binding, so a `const` field is never set inside a loop at all; that
  is also the rule a reader can apply by eye (recorded in section 22).
- **That exposed a real soundness bug, now fixed.** An `if` without `else` restored the
  state from before the block instead of merging with it. For "assigned" that is the same
  thing, since assignment only ever grows, which is why nothing noticed. It is not the same
  for narrowing: `if score != nothing { if reset { score = nothing } print(score + 1) }`
  passed `check` and then failed at runtime. It now intersects with the block's state when
  the block can complete. Guarded by `diagnostics/narrowing-undone-in-if` and
  `diagnostics/constructor-const-set-twice`; both were confirmed to fail with the merge
  removed.
- **Loops had the same hole, also fixed.** A loop body is checked once from the state
  before the loop, which is exact for assignment but not for narrowing, since a proof can be
  lost: `while i < 2 { print(x + 1); x = nothing }` passed `check` and failed on the second
  iteration. `forgetNarrowingAssignedIn` now drops the narrowing of every name a body
  assigns, anywhere in its nested statements, before the condition (or, for `for`, after the
  iterable) and the body are checked; the body proves it again if it can, so `while line !=
  nothing` still narrows and `latest = step * 10` still proves `latest` present below it.
  Lambda bodies are not searched, because a name a lambda assigns is never narrowed at all.
  Guarded by `diagnostics/narrowing-undone-in-loop`, confirmed to fail with the call
  removed, and `run/narrowing-through-loops` for what must keep working.
- **`self` is a keyword the parser turns into the name `self`.** Every later pass sees an
  ordinary name, so `self.x = 1` is an ordinary place assignment rooted at `self` and
  `self.items.append(1)` an ordinary changing method, reusing `resolvePlace`, copy-on-write,
  and the `const`-field checks unchanged. No program can declare that name, so it collides
  with nothing. Outside a constructor, and inside a block in one, the parser reports it and
  carries on rather than failing the statement, which would have reported the enclosing
  `}` as a second error.
- **A constructor is recorded as its type's body.** The resolver walks it under the struct's
  key, and records a call to a type the way it records a call to a function, so section
  7.1's capture check follows `make()` into `Badge()` into the module variable the
  constructor reads, with no new analysis. The checker stores the constructor's signature
  under the type's key too, which is what the interpreter widens arguments through.
- **Argument checking is now shared by functions and constructors.** `checkArguments`
  replaced the named-function copy, and the defaults slice moved the generated constructor
  onto it too; only `typeOfValueCall` keeps its own.
- **At runtime the instance exists before the body runs.** `constructStruct` creates it with
  every field holding `nothing` and hands it to `invoke` as `Callable.constructing`, which
  binds it as `self` and produces whatever `self` holds when the body ends. That is not
  necessarily the starting instance: `opened.append(self)` followed by `self.balance += 1`
  copies, so the stored value keeps the old balance, which `run/struct-constructor` checks.
  The checker's readiness rules are what keep the placeholder `nothing`s unobservable. A
  stack trace names the frame "the constructor of `Account`", computed once per type rather
  than per construction; two million constructions in a loop ran in flat memory (1.9 MB).

### Struct diagnostic decisions worth knowing

- **A struct body recovers one member at a time** (`Parser.parseStructMember`), as a block
  recovers one statement at a time. Before chunk 6 of the review, any fatal parse error
  inside a struct also reported the struct's own `}` as "does not close anything".
  `diagnostics/struct-member-habits` fails without it.
- **Other languages' spellings get Emerald's.** `static`, `init(...)`, `func constructor`,
  `self` in a parameter list, a field without `var` or `const`, a property without a type,
  and `name = value` in a call each have their own message and correction
  (`diagnostics/struct-member-habits`).
- **A bare member name inside a type's own code says how to reach it.** The resolver works
  out the enclosing type from `current_function` (`enclosingType`) and, for a name that is
  one of its members, reports "reached through `self`" or "reached through the type"
  instead of "not defined"; `this` is answered with `self` (`diagnostics/member-without-self`).
- **Smaller wording and span fixes.** Argument-count errors on a method call underline the
  method's name, as its other diagnostics do; a property read or setter assignment in the
  capture check is no longer called a "call"; the duplicate-constructor correction points
  at a type-level function; a type-level field with no value is underlined at its name; the
  field-order corrections name the field to move; and a binding taken by a setter says
  "changed by setting `reading`" (`Heap.Binding.Change.setter`), which made no measurable
  difference to assignment or call timing.

### Struct decisions worth knowing

- **Type identity is a stable metadata pointer.** Every reference to one declared struct
  shares a `Type.User`; its ordered checked fields are filled only after all struct names
  have been hoisted. This permits forward and cross-file field types without equating two
  same-named types from different namespaces.
- **The generated constructor is positional and follows declaration order.** Required
  fields are checked and evaluated left to right, with `Int` widened when the field expects
  `Float`. Defaults and custom constructors remain separate later slices.
- **Runtime instances are managed objects.** They own a compact field-value slice and point
  to an arena-owned descriptor carrying names and runtime kinds. Reference counting handles
  ordinary lifetimes, and the collector traces struct fields and reclaims cycles through
  closures. This keeps the universal `Value` pointer-sized.
- **Key eligibility waits for every field type.** A struct may be a dictionary key only
  when its fields recursively qualify. The checker deliberately validates this after all
  struct metadata is complete, so a field that refers to a later declaration gets the same
  answer regardless of file or declaration order.
- **Qualified type spelling follows namespace aliases.** Direct `Left.Marker`, a focused
  alias, and a namespace alias such as `using L = Left` followed by `L.Marker` all resolve
  in annotations as they do at construction sites.
- **Runtime descriptors keep identity and display names separately.** The resolver key
  remains the stable identity used for hashing, while values print the declaration spelling.
  This matters for private types: `_Marker(1)` now displays as `_Marker(value: 1)` rather
  than exposing the internal `<file>.em#_Marker` key.
- **A hoisted struct type is complete while its file initializes.** Reaching its generated
  constructor during that file's own initialization is no more an initialization cycle than
  calling one of its hoisted functions. `reach` exempts both, while reads of unfinished
  value bindings still raise the cycle error.
- **NaN rejection follows struct fields recursively.** A struct key is accepted only when
  its field types qualify, and the runtime guard now also descends into the actual field
  values. Once Emerald gains a way to produce NaN, hiding one inside a struct cannot bypass
  the dictionary/set rule.
- **A place is one path, walked once, whichever kind it passes through.**
  `checkAssignment`/`assignElement` used to know only about list and dictionary indices.
  They now walk a path of `Ast.Step`s — index or field — built once by the parser from
  `a.b[i].c`, and `requireMutableReceiver` and `requireChangeable` (the two changing-method
  checks, for dictionaries and lists respectively) share the same walk through a new
  `walkToPlaceRoot`, so `bag.values.append(2)` and `bag.values = other` are checked by one
  piece of code apiece rather than two. `Heap.uniqueStruct` mirrors `unique` and `uniqueMap`
  exactly, so `line.start.x = 1` copies `line`'s instance the first time it is shared, the
  same way `scores.append(1)` already copied a shared list.
- **`const` freezes a field where it sits, not only at the top.** `line.start.x = 1` is
  rejected when `start` is `const`, even though `line` itself is a `var` — section 4.3 says
  a `const` field "can be neither replaced nor changed", which only becomes checkable once a
  field can hold another struct. `walkToPlaceRoot` checks every field step's mutability on
  the way down. The first version learned each step's owner type by calling `self.typeOf` on
  it again, on the theory that the caller had already type-checked the whole chain once and a
  successful `typeOf` reports nothing. That theory was wrong: a capture error inside an index
  expression, such as `grid[pick()].values.append(1)` where `pick` reads an unassigned module
  variable, is reported on a successful call too, so the diagnostic printed twice. It now
  recurses to the root first and carries each step's type back out through the recursion —
  from the root binding, or from the previous step's field type — so no subexpression is
  type-checked a second time. Guarded by `diagnostics/capture-error-through-struct-field`.
- **A tuple position can never be part of a mutable path.** `pair.0 = 1` is rejected in the
  parser, before a type even exists to consult, because section 8.2 gives no way to write
  through a tuple position at all. The same rejection covers `pair.0.append(x)` in
  `walkToPlaceRoot`, so a list held in a tuple position cannot be mutated through the
  position either — a tuple position has no `var`/`const` distinction because nothing about
  it can ever change, unlike a struct field.
- **Assigning through a namespace was deliberately not attempted, and needed two different
  answers.** For plain `=`, `Shapes.origin.x = 1` reaches the resolver as the bare name
  `Shapes`, because member access is walked the same way any other step is; the resolver's
  existing "`Shapes` is a namespace, not a value" diagnostic already covers it correctly,
  with no new code. A changing method does not go through that resolver path at all — it is
  an ordinary call, so `Shapes.scores.append(4)` resolves `Shapes.scores` to a real key
  through the same `qualify` the resolver already uses for `Shapes.area(3)`, and `check`
  reported nothing. `walkToPlaceRoot` now checks `self.facts.qualified` at each member step
  before treating it as a field, and reports its own "changing a value through its namespace
  is not available yet" rather than reaching a root that is not a real binding. Found by
  running the program rather than by reading the code: it printed "No problems found" and
  then crashed. Guarded by `diagnostics/qualified-struct-field-mutation`.
- **`assignElement` and `callChangingMethod` were missing lazy initialization, an existing
  bug this slice made easier to hit.** Section 14.1's rule is that a non-entry file
  initializes on first use, and every access to a module-level key is supposed to call
  `reach` first; plain assignment already did this, but index and field assignment, and
  every changing method, went straight to `self.find(name).?` and crashed once the name
  belonged to a file that had not run yet. `using Shapes` followed by `scores[0] = 1` or
  `scores.append(1)` crashed before this slice too — confirmed by stashing the whole diff and
  reproducing it on the prior commit — so this was not a new defect, only a newly exercised
  one. Both functions now call `reach` before `find`, matching plain assignment. Guarded by
  the project case `run/lazy-module-list-mutation`.
- **A field reached through an optional needs its own correction.** `h.maybe.x = 1`, where
  `maybe` is a field rather than a binding, cannot be told to "check `h` first" — `h` is not
  optional, `h.maybe` is, and there is no name to write into the message the way there is at
  the root. It now says to read the value into a `var`, check that, and assign it back.
  Guarded by `diagnostics/nested-optional-field-path`.

### Dictionary and set decisions worth knowing

- **A set is a dictionary that stores no values.** One `Heap.Map` backs both, with an
  `is_set` flag deciding what it stores and how it prints. Section 8.4 asks the same things
  of both — insertion order, equality by contents, deterministic iteration — so writing
  them twice would have meant getting the same rules right twice.
- **Insertion order is the array; the hash table holds indices into it.** That is what
  makes 8.4's rules fall out rather than be maintained: replacing a value keeps its
  position because the entry does not move, and removing and reinserting a key moves it to
  the end because appending does that.
- **Every entry keeps the hash it was stored under.** Hashing a string means normalizing it
  (9.2), which is the expensive part, so a stored hash makes rebuilding the table after a
  removal cheap and lets a lookup rule out almost every entry before comparing anything.
- **Hashing has to agree with `==`, and `1 == 1.0`.** So `Int` and `Float` share a hash tag
  and a whole `Float` hashes as the `Int` it equals. In practice a dictionary's keys are
  all one static type and are widened on the way in, so the case cannot arise today — but
  the invariant the file claims is then true unconditionally rather than by accident.
- **Printing says which of the three a collection is.** The literals overlap, so an empty
  dictionary prints `[:]` and a set prints the braces of its type. Recorded in 8.2 and
  section 22.
- **A method is reached exactly once, whichever kind its receiver is.** An earlier version
  probed the receiver by evaluating it to see whether it was a map, which made
  `input().to_int()` read two lines. Dispatch now decides from the method's name whether it
  changes its receiver, and reaches the receiver once either way.

### Tuple decisions worth knowing

- **Why tuples came before dictionaries.** Section 8.6 iterates a dictionary as `(key,
  value)` tuples and says plainly that "there is no second implicit `key, value` calling
  convention", so `ages.each { (name, age) => ... }` cannot be written without them.
  Splitting them out keeps the dictionary slice about dictionaries.
- **A tuple widens position by position; a list does not.** Nothing can assign to a tuple
  position, so a `(Int, Int)` used as a `(Float, Int)` can never be written through and
  observed as the wrong type — which is the whole argument that makes a list invariant.
  Recorded in 8.2 and section 22.
- **A tuple is never copied.** It is counted like a list and traced like one, but there is
  no copy-on-write, because there is no way to change one after it is built.
- **`entry.0.1` is a lexical problem, solved in the parser.** The lexer reads `0.1` as one
  decimal number, since a `.` between two digits is a decimal point. The parser splits it
  back into two positions in the one place that already knows a member is being named.
  The alternative was making people write `(entry.0).1`.
- **Unpacking is one operation in four places.** A declaration, an assignment, a `for`
  binding, and a block's parameters all reach `unpackInto`, and the checker reaches
  `bindPattern`. The four differ only in whether the names are being introduced and what
  kind of binding they become.
- **A restriction that was invented and then removed.** The first version rejected
  `("x", nothing)` as a position with no useful type. Nothing else in the language does
  that — `[nothing]` and `const c = nothing` are both accepted — so it was a rule this
  slice had no business adding. If bare `Nothing` is worth rejecting it is worth rejecting
  in all three places, as its own decision.

### Project decisions worth knowing

- **The directory is the namespace; the file names nothing.** Section 24 recorded that 14.2
  read both ways — whether `shapes/circle.em` names a module `Shapes.Circle` or only a
  namespace. It names only a namespace. 14.3 had already dropped filename-as-implicit-type
  and 14.2 makes same-directory names directly visible, so the file cannot be part of the
  name without contradicting both. The practical effect is that splitting one file into two
  changes nothing any other file writes, which is the refactor a growing program reaches for
  first. Recorded in 14.2 and in section 22.
- **The file is still the unit of initialization and of privacy.** The two questions are
  separable: the directory answers "what is this called", the file answers "when does it
  run" and "who can see it". That is what lets two files in one directory each declare a
  `_helper`.
- **Every module-level name becomes one key, and almost nothing else changed.** The
  resolver, checker and interpreter all keyed their module scopes by name already. Making
  the key `Shapes.area` for a public declaration and `shapes/circle.em#_twice` for a
  private one meant those three passes needed a translation step at exactly one place each,
  rather than a new concept. `#` cannot appear in an identifier, so a private key can never
  collide with a qualified one.
- **`Shapes.area` is decided once.** It parses as a member access, and whether it is one is
  a question only the resolver can answer. It records the answer in `Facts.qualified`,
  keyed by the expression node, and the checker and interpreter read it rather than folding
  the chain again — the same pattern as `literal_types`.
- **Module variables are hoisted across the whole project, and the ordering rule became a
  span comparison.** They used to enter the module scope as the walk reached them, which
  works in one file and fails in many: whether `grades.em` could see `scores.em`'s
  `pass_mark` depended on which was walked first. They are now hoisted like functions, and
  section 7.1's "variables are visible only from their declarations" is enforced by
  comparing spans within one file. The example found this, not a test.
- **A block carries the file it was written in.** A block passed to another file and called
  there is still the block that was written where it was written, so `Heap.Closure` holds
  its file for the same reason it holds its scopes.
- **Only the entry file's top level runs, so a binding elsewhere needs its value where it
  is written.** There is nowhere else an assignment could happen. Reporting it at the
  declaration beats letting definite assignment report it at every read.

### Optional decisions worth knowing

- **An optional is a flag on the type, not a wrapper.** Section 4.5 settles that optionals
  never nest, so there is nothing a second layer could mean and no way to build one by
  accident. `Int?` costs exactly what `Int` costs, and at runtime an optional is simply the
  value or `nothing` — no boxing, no allocation, nothing for the collector to trace.
  Placement stays structural: the flag on a list is `[String]?`, the same flag on its
  element is `[String?]`.
- **Narrowing lives in the same state that definite assignment lives in.** `Snapshot` grew
  from a bool per binding to `{ assigned, type }`, so every place that already saved,
  restored, intersected, or merged flow state now does the same for what narrowing proved.
  That is what makes narrowing stop at the end of a branch, at a loop, and at a `break`
  without any of those places knowing about optionals.
- **A `var` a block assigns to is never narrowed.** Section 4.5 says the proof is lost when
  "a called closure could reassign its captured binding". The resolver already walks lambda
  bodies, so it records `assigned_in_lambda` and the checker refuses to narrow those names
  at all. A `const` and a parameter always narrow, because they cannot be rebound.
- **Nor is a module variable a function assigns.** A function reaches a module variable
  just as a closure reaches a captured one, and the chunk 2 review found `check` accepting
  `if name != nothing { clear(); print(name.count) }`, which panicked at runtime; the hole
  predated the struct slices. The resolver records `assigned_in_function` (by module key,
  for any body with `current_function` set), and `Checker.unprovable` refuses both kinds,
  with a correction that says why a test cannot help and suggests a `const` copy. Guarded
  by `diagnostics/narrowing-lost-to-function`.
- **`.or(...)` is lazy and is the one method allowed on a value not yet proved present.**
  Supplying the fallback is what proves it. The fallback is evaluated only when it is
  needed, matching the `or` operator's short-circuiting.
- **Every place that reached into a value had to learn to ask first.** `requirePresent`
  guards member access, indexing, method calls, iteration, and element assignment. Two of
  those were found by trying them rather than by reading: `for x in maybe_list` and
  `maybe_list[0] = 1` both crashed the interpreter before the guards went in.

### Collector decisions worth knowing

- **The roots are derived, not registered.** Section 19.5 asked for an explicit root API,
  which would mean registering every temporary the evaluator holds across an allocation.
  The counts already say the same thing and say it more safely: every holder retains, a
  count may be too high but never too low, so an object whose count exceeds the references
  coming from other managed objects is held by something outside the heap. That is exactly
  the root set, including every `Value` sitting in a Zig local. The decisive argument is
  the failure mode — a missed registration frees a live object, while a count that is too
  high only delays a free. Recorded in 19.5 and in section 22.
- **Literal strings are roots.** They are never counted, so counting holders of one would
  make it look like garbage. `collect` marks every `literal` text unconditionally.
- **Sweeping drops the garbage's references to survivors.** A dead cycle can hold a live
  string; freeing the cycle without decrementing would keep that string for the whole run.
  The sweep does that in a pass before it frees anything, so no free cascades into another.
- **Tracing can fail.** The worklist needs memory. When it cannot grow, `collect` returns
  having freed nothing, which is always correct — the heap is exactly as it was.
- **Collection happens before allocating, not after.** Called at the top of each `create`,
  so a half-built object is never exposed to a trace.
- **How it was verified.** The whole suite, every example, and every conformance case were
  run with the threshold forced to collect before every single allocation, in Debug and
  ReleaseSafe. Each collector test was also confirmed to fail with the sweep disabled or
  the list roots removed, so none of them is vacuous.

### Callable decisions worth knowing

- **A scope is an object, not a stack frame.** Section 7.4 captures by reference, so a block
  and the code around it must keep sharing one variable. `Heap.Environment` is counted like
  a list; `popScope` recycles it only when nothing captured it, so a loop body that creates
  no closure still allocates nothing. A closure holds the whole visible scope chain rather
  than a computed capture set, which costs one pointer per enclosing block and needs no
  analysis in the resolver.
- **Why the collector became its own slice.** Counting reclaims everything the earlier
  slices can build, because value-typed data cannot form a cycle. A closure can: store a
  lambda in a variable it captures and the closure and the environment hold each other
  forever. The collector arrived in the next slice and now reclaims exactly that.
- **The parser decides a lambda's body shape from the source, not a token.** `=>` continues
  a line like any other operator, so the lexer has already dropped the newline after it.
  `brokeLine` reads the bytes between `=>` and the next token instead. This was a real bug:
  every block-bodied lambda parsed as an expression body until it was found.
- **A named function value and a lambda are one runtime kind.** `Heap.Closure` holds either,
  and `closureCallable` turns both into the same `Callable`, so `invoke` is the only place
  that knows how a call works. `callFunction` is just the direct-call shortcut that skips
  building a closure.
- **`each` and `map` are checked directly rather than through the method table.** Their
  argument and result types are both stated in terms of the receiver's element type, and
  `map`'s result comes from the block, which `Type.ListMethod`'s fixed operand enum cannot
  express. A function type whose result is `invalid` is how the checker asks for a block
  without constraining what it produces.
- **The checker records a lambda's type in `literal_types`.** It is the only place the
  parameter and result types are known, and the interpreter needs them to widen arguments
  and results the way section 4.4 allows, exactly as it reads a named function's signature.

### String decisions worth knowing

- **Unicode is generated, not hand-written.** `tools/unicode/fetch.sh` downloads the
  database, `tools/unicode/generate.zig` writes the tables (then `zig fmt` them), and
  `zig build unicode-conformance -Doptimize=ReleaseSafe -- <dir>` checks the whole
  NormalizationTest: 20,034 cases plus the rule that every one of 1,094,978 unlisted code
  points is its own NFC, with no failures. Regenerating reproduces the committed tables
  exactly. The routine suite embeds all 766 GraphemeBreakTest cases and every
  NormalizationTest part but Part 1, which is 2.8 MB.
- **The lexer emits an interpolated string in parts** (`string_start`, `string_middle`,
  `string_end`) around ordinary expression tokens, tracking a stack of open
  interpolations and the braces inside each, so quotes and braces inside `#{...}` belong to
  the expression. A string that began inside an interpolation and ran off its line is
  reported as the unclosed `#{`, which is almost always the real mistake.
- **The parser cooks strings once**: escapes, `\u{...}`, triple-quoted layout, and
  Windows line endings. The AST holds finished text. Triple-quoted layout errors (text on
  the opening line, a closing delimiter sharing a line, a line indented less than the
  closing delimiter) are all parser diagnostics.
- **Names are XID and NFC.** The lexer accepts Unicode identifier characters (which leave
  out emoji, so no separate emoji rule is needed) and the parser normalizes any name not
  already in NFC at the one place every stored name passes through, `Parser.identifier`.
  The long-standing rough edge about accepting any non-ASCII byte is closed.
- **Strings are immutable heap texts** with counts, sharing freely. A literal's text lives
  in the syntax tree and is wrapped once per literal as a "literal" text that is never
  counted, so a loop printing a literal does not allocate.
- **Equality and ordering normalize only when they must.** Identical bytes are equal, two
  strings the quick check says are already NFC compare as bytes, and only otherwise is
  anything normalized. `Value.equals` now takes an allocator for that reason.
- **Searching respects characters** (recorded in 9.2): matches must start and end on
  grapheme boundaries of the normalized haystack, so `"café".contains?("e")` is false.
- **`+` joins strings** and `+=` appends (user decision pending confirmation; recorded in
  the section 22 table). A reference-count bug was caught while adding it: `applyBinary`
  released its operands, but compound assignment passed a binding's value unretained. Now
  no operator releases operands; callers own them, and compound assignment holds the
  current value while the right side runs, since that could reassign the same name.
- **`input` reads from a stream the CLI passes in**, and the conformance runner feeds a
  `.input` file beside a case. End of input is a runtime error until optionals bring
  `input_maybe`; so is a line that is not valid UTF-8.
- **Stack budget.** Adding cases to `evaluate` pushed its Debug frame past what 1,000
  calls at 250 levels of nesting fit in; the fix, now a comment in `evaluate`, is that
  every case needing locals lives in a function of its own.
- Performance: 200,000 interpolations with `upper` and 50,000 `contains?` calls run in
  0.7 s in ReleaseSafe.

### List decisions worth knowing

- **Scope** (user-approved): lists only. Dictionaries and sets need string keys to be
  useful, and `first`, `last`, and `each` need optionals and lambdas.
- **Value semantics are reference counts with copy-on-write** (`Heap.zig`), as planned. A
  "shared bit" cleared only by a future collector was considered and rejected: passing a list
  to a function would mark it shared for good, so a loop calling `f(xs)` then
  `xs.append(i)` would copy the whole list every iteration. With counts, 200,000 such
  iterations take 0.09 s. The rule the interpreter follows: every new holder retains (a name
  read, a retained element, a loop snapshot), every holder that ends releases (a scope
  closing, an overwritten binding, a consumed temporary). Counts may run high, which only
  costs a copy; they must never run low. Every buffer is also linked into `Heap.live`, and
  `Heap.deinit` frees whatever is left, so error paths cannot leak. A unit test pins flat
  memory, and was confirmed to fail when `popScope` stops releasing.
- **A buffer records its element kind**, because runtime has no static types but a `[Float]`
  must store `rates.append(2)` as `2.0`. List literals get their element type from the
  checker's `literal_types` table, which is how `var rates: [Float] = [1, 2]` stores
  Floats.
- **Expected types flow into list literals** (`typeOfExpected`): from annotations,
  assignment targets, parameters, method arguments, return types, and the other side of a
  comparison. Only literals use them. Without context, a literal infers its element type and
  widens `Int` beside `Float`; `[[1], [2.5]]` without an annotation is rejected, since the
  inner lists are typed before they meet. Lists are invariant everywhere else, with their
  own correction.
- **Where a list changes**: element assignment and mutating methods evaluate their indices
  and arguments first, then walk to the target, making each list on the way unique. Walking
  afterwards is what keeps a pointer valid when evaluating the value itself changes the list.
- **Mutation is checked in the checker, not the resolver**, because whether a method mutates
  depends on the receiver's type. Checker bindings carry a `Mutability`, and each reason a
  change is refused has its own correction: `const`, parameter, loop variable, or a temporary
  like `make().append(1)`.
- **Unknown members suggest Emerald's name** for another language's (`push` → `append`,
  `length` → `count`), and `count()` and a bare `append` explain properties versus methods.
- **`5..1` is now an error** (the user chose error over warning, recorded in 6.4), for two
  literal endpoints only.
- **Counting down** (user-approved, recorded in 6.4): `a.down_to(b)`, `a.up_to(b)`,
  `.step(n)`, and `.reverse()` are loopable directly, alongside ranges. A wrong-side target
  counts nothing, which replaced the spec's earlier "error on a wrong-side target" rule so
  computed bounds stay safe in both directions; two literals that can only be empty are an
  error. `Checker.isCounting` recognizes these forms by shape, since none is a value a
  program can hold yet, and the interpreter normalizes each to a `Counting` whose `last` is
  a value the count actually reaches, so the loop stops by comparing and never steps past
  either end of the `Int` range, and `reverse` swaps ends exactly.
- **Member access and indexing** are postfix operators chained with calls, so
  `grid[0].append(1)` and `make()[0]` parse; `?.` reports that optional chaining is not
  available yet.

### Loop decisions worth knowing

- **Definite assignment through loops** (recorded in 6.4). A body is checked from the state
  before the loop, which is exact for the first iteration and conservative for later ones,
  since nothing becomes unassigned. After a loop, only what was assigned before it is known,
  because the body may run zero times; a name lost that way gets its own correction ("the
  loop that assigns `x` might not run at all"). A literal `while true` is the exception:
  after it, a name is assigned when every `break` assigned it (`Checker.Loop.exits`), and
  one with no `break` never completes, so a function may end in it.
- **"Always returns" became "completes".** The checker's control-flow shape now asks
  whether a block can fall off its end (`blockCompletes`), so a branch ending in `break` or
  `continue` is left out of the merge after an `if` exactly as a returning one was, and the
  every-path-returns check accepts a body ending in `while true`.
- **Trailing `if` is parsed into an ordinary `if`** with no `else` whose block holds the one
  statement, flagged `trailing` for the future formatter. No pass after the parser treats it
  differently. It is accepted after calls, assignments, `return`, `break`, and `continue`, and
  rejected after a declaration. `return if cond` is a bare return with a guard; when the
  `if ... then ... else` expression lands, `return if a then b else c` will need to be told
  apart by looking for `then` on the same line.
- **Ranges are ordinary expressions** at their own precedence level, between comparison and
  arithmetic, so `0..count - 1` ends at `count - 1`. The checker accepts one only as what a
  `for` loop visits, and the interpreter reads its endpoints there directly rather than
  building a range value. `for` stops by comparing with the last value, so a range ending at
  the largest `Int` does not overflow.
- **`break` and `continue` unwind as Zig errors** (`Broke`, `Continued`), the same way
  `return` already did; the checker guarantees a handler for each, and a function body starts
  with no enclosing loop.
- **Parse recovery skips a whole block** when the failed line opened one, so a broken loop or
  `if` header no longer reports its closing brace as a second error. A stray top-level `}`
  now says it closes nothing.
- **Performance, found by timing the first long loops.** Zig 0.16 gives a ReleaseSafe build
  without libc its leak-checking `DebugAllocator` as `init.gpa`, which made a loop that
  declares a local about 7 µs per iteration. `main` now uses `std.heap.smp_allocator` outside
  Debug, and the interpreter reuses emptied scope tables. Ten million iterations went from
  39 s to about 1 s in ReleaseSafe, with flat memory. The remaining cost is name lookup
  through hash maps; resolving names to slots is the obvious next step if it matters.
- **The leading dot** (recorded in 3.1) is implemented in the lexer
  (`nextLineLeadsWithDot`). Member access itself is not parsed yet, so it is covered by a
  lexical conformance case until the collection slice.

### Function decisions worth knowing

This slice was first built with function bodies isolated from the module scope entirely, to
sidestep the problem that a hoisted function can run before a variable it reads is assigned.
That design was replaced before commit, because it contradicts section 6.1 (which presumes
module names are visible inside functions) and section 7.1 (functions capture surrounding
bindings), and because it rejected one of the most common programs a beginner writes: a
module-level `const` read by a function. Section 7.1 names the actual problem and the
actual rule — "hoisting never permits reading an uninitialized captured variable" — so
that rule is what is enforced instead. Do not reintroduce the isolation.

- **Visibility follows the text.** Functions are hoisted; variables are visible only below
  their declaration, inside function bodies too (section 7.1). A function sees the module
  variables declared above it. Using one declared below gets a diagnostic that says exactly
  that, rather than a generic "not defined".
- **Section 7.1's capture rule is checked statically, at each call made from top-level
  code.** Every module variable the callee reads, directly or through the functions it
  calls, must already be assigned there. Calls inside function bodies need no check of their
  own, since a caller's captures include its callees'.
- **Function bodies are checked after the top level**, against a view of the module scope in
  which everything counts as assigned: a function can run at any point, so the state at the
  place it happens to be written means nothing inside it. A body is checked early only when a
  call needs its inferred return type, and any gap in its view at that point is guaranteed to
  coincide with a capture error at that call.
- **Functions and variables share one namespace**, as section 7.3's "a name declares one
  function" implies. A program function may shadow a prelude function, as a variable may.
- A function with no result returns `Nothing`, and a recursive one needs no annotation,
  since its return type is known without inference. The user settled this (7.2 now says
  so directly), replacing a "no result" category that differed from `Nothing` in name
  only.
- Widening happens at calls too. The checker exports its signatures, including return types
  it inferred, and the interpreter widens arguments to parameter types and results to return
  types, so `return 1` from a function whose returns merged to `Float` yields `1.0`.
- **The host stack.** A probe showed the default stack exhausted between 600 and 800 calls
  in Debug, short of section 7.2's 1,000, so the whole pipeline runs on a thread with a
  512 MiB reserved stack (address space, not memory), and the interpreter raises before
  exhausting it whatever the program's shape. The parser bounds everything upstream: exactly
  256 levels of delimiter nesting (section 3.4, reported at the delimiter that crosses it),
  a separate budget for recursion that opens no delimiter, and a tree height of 10,000 so a
  long flat chain such as `1 + 1 + ... + 1` is a diagnostic rather than a crash. One unit
  test proves 1,000 calls at 250 levels of nesting in Debug; it peaks around 340 MB resident
  while it runs.
- **No fallback stack.** If the large-stack thread cannot be created, `emerald` exits `70`
  (internal failure) rather than running on the calling thread. Probing the old fallback
  showed nothing crashed on an 8 MiB main thread, but legal programs failed there, and the
  fallback had to assume a stack size the host chooses (1 MiB on Windows), which could make
  the guard wrong. Single-threaded builds are a compile error for the same reason.
- **Memory per call is freed.** Scopes, arguments, and the call stack come from the general
  allocator and are released as each block or call ends; only module bindings, hoisted
  functions, and the final failure live in the run's arena. This was done before loops,
  which would otherwise have grown memory with every iteration. A unit test pins it by peak
  memory: 32,767 calls must cost no more than 15.

### Review fixes

An external review of slice 7 found these, all verified by reproduction before fixing and
each now covered by unit tests and conformance cases:

- `true == true` and `nothing == nothing` passed checking and then failed at runtime. Every
  type now has `==` and `!=`; the ordering operators are rejected statically on anything but
  numbers (recorded in 5.2 of the rewrite context). When strings land, the "only numbers are
  ordered" diagnostic has to gain strings.
- `print` wrote each argument as it was evaluated, so an argument that printed interleaved
  with the line being built, and a failing argument left half a line. It now evaluates every
  argument first, like any other call.
- `-9223372036854775808`, the minimum `Int`, was rejected because its digits alone are out
  of range. The parser reads the minus and that literal together, but only when the minus
  applies to the literal alone: `-9223372036854775808 ** 2` is still out of range.
- `const limit: Int` was accepted though nothing could ever assign it. It is now rejected in
  the resolver, which runs before the checker, and later assignments to it are not reported
  again (recorded in 4.1 of the rewrite context).
- Stack fallback and per-call memory, described under the function decisions above.
- Not from the review: internal failures such as running out of memory escaped `main` as a
  raw Zig error with status `1`, colliding with source diagnostics. They now print one line
  and exit `70`, as section 18.1 specifies.

The review also restated the Unicode identifier gap known at the time; the string slice
later closed it (see "Names are XID and NFC" above).

### Checker decisions worth knowing

- Section 4.4 describes numeric widening as applying "where arithmetic requires it", but
  the same section relies on it to infer `[Float]` for `[1, 2.5]`, which is not arithmetic.
  It is read here as applying wherever a value meets an expected numeric type, so
  `var rate: Float = 1` is accepted. **Worth confirming**, since it is an interpretation
  rather than a quotation.
- Widening has to actually happen, not merely be permitted. Accepting `var rate: Float = 1`
  statically while storing an `Int` made `rate` print as `1` rather than `1.0`, with the
  static type and the runtime value disagreeing. The interpreter now carries the kind each
  name holds and converts on declaration and assignment.
- `count /= 2` where `count` is an `Int` can never type-check, because section 5.3 lowers
  `/=` through `/` and `/` always produces a `Float`. That is a consequence of two settled
  rules rather than a bug, but the cause is far from the line that fails, so it gets its own
  diagnostic naming the operator and suggesting `//=`.
- An expression whose type could not be determined becomes `Type.invalid`, which is
  compatible with everything. One mistake therefore produces one diagnostic instead of one
  per enclosing expression, which is section 17.2's rule against cascades.
- Definite assignment merges branches by intersection: a name is assigned after an `if` only
  when both a `then` and an `else` assign it. An `else if` chain without a final `else`
  proves nothing, because a path through it assigns nothing.

### Statement decisions worth knowing

- Name resolution is its own pass, so shadowing, undefined names, and assigning to a `const`
  are reported by `check` rather than only when a line happens to run.
- Section 3.4's brace style puts `else` on its own line, so a newline always sits between
  `}` and `else`. That newline terminates a statement everywhere else, so the parser looks
  past it only once an `else` is known to follow.
- The prelude is a scope of its own, below the program's. That is what lets a program
  declare a name matching a prelude function without it counting as the shadowing section
  6.1 forbids, matching the rule that a local may reuse a module-level name.
- A comparison chain is one node holding all its operands. That is what makes "evaluate the
  middle expression once" and "short-circuit as if joined by `and`" fall out naturally
  rather than being reconstructed by the evaluator.
- Section 4.4's mixed comparison rule rules out the obvious implementation: widening the
  `Int` to a `Float` first would make `9007199254740993 == 9007199254740992.0` true, which
  is the accidental equality the rule exists to prevent. `Value.order` splits the float
  instead.
- `Nothing` arrived with this slice rather than later, because `print` had been returning a
  placeholder `Int` that `var x = print(1)` would have exposed as a lie.

### Expression decisions worth knowing

- The right operand of `**` is parsed as a unary expression rather than as another power.
  That one rule gives the operator its right associativity, lets `2 ** -3` parse, and still
  leaves `-2 ** 2` meaning `-(2 ** 2)` because unary sits above it.
- Section 9.4's float display is written out in `Value.zig` rather than inherited. The host
  disagrees on every interesting case: it renders `2.0` as `2`, `-0.0` as `-0`, `1e16` in
  fixed form, and the special values as `inf` and `nan`.
- Zig's `@divFloor` and `@mod` were verified by probe to match section 5.3 exactly,
  including negative divisors and the law `a == (a // b) * b + (a % b)`.
- Section 5.2's rule that a standalone pure expression is an error is enforced in the
  parser, which is why a program is currently a sequence of calls.

### Lexical decisions worth knowing

- A newline is emitted only when the previous token can end an expression and no `(` or `[`
  is open. Braces deliberately do not open a group, so statements inside a block still end
  at a newline. Because `.newline` itself cannot end an expression, runs of blank lines
  collapse with no special handling.
- Section 3.3 lets a name end in `?` or `!`, which collides with `?.` and `!=`. A trailing
  marker joins the name unless the next character forms the operator, so `user?.name` and
  `a!=b` lex correctly while `empty?()` and `sort!()` keep their markers. The section 4.2
  conformance case `func valid?(input: Int?): Bool` is covered by a test.
- A `.` is a decimal point only when a digit follows, which is what keeps `5.times` a method
  call and `1..5` a range rather than malformed numbers.
- Documentation comments are tokens because the parser needs them. Line and block comments
  are skipped, which the formatter slice will have to revisit.

## Code review of the struct slices

Complete. The struct slices (`72e7df4..a90ed94`: constructors, methods, properties, defaults
and named arguments, type-level members) were reviewed in six chunks, one area at a time,
each checked with small `.em` programs in Debug and ReleaseSafe. Every confirmed problem got
a fix and a conformance case, and design decisions went into `docs/rewrite-context.md`. What
each chunk changed is described in the decision sections above; this table is the record of
what was covered.

| Chunk | Area | Status |
| --- | --- | --- |
| 1 | Receiver handling in the interpreter: `callStructMethod`, `takeReceiver`, `assignElement`, `storeProperty`, `evaluateReceiverPath`. Values put back and counted on every path, and binding pointers held while the module scope can move | Done, fixed in `b7c3b64` |
| 2 | Constructor field tracking (`.x` and `!x` bindings) under `return`, `break`, `continue`, `while true`, and nesting; the `if` and loop narrowing fixes | Done, fixed in `5d72c7c` |
| 3 | Type-level members: setup order and cycles, the section 7.1 capture check through `Resolver.typeSetupKey`, `settleTypeField` and the `inferring` set, the `find` redirect, the assignment rewrite through `Facts.type_assignments`, namespaced and private types, name clashes with instance members | Done, fixed in "Fix type-level member issues found in review" |
| 4 | Which methods change `self` (`methodChanges` and its caching, `selfPathType`), the rule that a getter may not change `self`, assignment through properties, and nested changes through them | Done, fixed in "Fix property clash crash found in review" |
| 5 | Defaults and named arguments: the checker and interpreter matching arguments to the same parameters (`src/arguments.zig`), which file and frame defaults run in, and field defaults under both kinds of constructor | Done, fixed in "Fix argument handling found in review" |
| 6 | Diagnostic wording and spans across all five slices: wrong or misleading messages, cascades, and underlines in the wrong place | Done, fixed in "Improve struct diagnostics found in review" |

## Second code review (section 7 and the last struct slices)

Reviewed `8ced94f..7ad9887` in six chunks, inline; complete. Design questions found in review are decided
by the reviewer against Emerald's philosophy and modern language design, not put to the user.

| # | Scope | Status |
| --- | --- | --- |
| 1 | Nested functions: resolver capture analysis and use checks | Done: destructuring-assignment crash and recursion false positive fixed |
| 2 | Nested functions: checker body checking and runtime hoisting | Done: a local now hides an imported function in a call (an older bug next to the new code) |
| 3 | Method values: receiver copy, write-back, collector, re-entry | Done: no method value bugs; two calls' nested functions no longer compare equal |
| 4 | Privacy: every path to a member | Done: 15 outside paths and the inside ones all held; messages that sent a private member the other way now report privacy, and nested functions in methods got their member hints back |
| 5 | Nested tuple patterns and parser changes | Done: nesting held everywhere; a trailing comma in a pattern and a standalone lambda that unpacks a tuple (both older) fixed |
| 6 | Diagnostics across all four slices | Done: a variable declared below a nested function is named as such, the "declared later" help names the variable, and the narrowing help mentions nested functions |

## Third code review (the object model slices)

Reviewing `8015cde..93cb720` (classes, inheritance, type tests, traits, `Self` and operators,
enums and `case`) in seven chunks, inline, adversarially: each claim is attacked with small
`.em` programs in Debug and ReleaseSafe, every confirmed problem gets a fix and a conformance
case, and design questions are decided by the reviewer.

| # | Scope | Status |
| --- | --- | --- |
| 1 | Classes: sharing through every place and method path, the `const` boundary, identity, cycles in display and the collector, blocks and nested functions using `self` | Done: releasing a long object chain no longer overflows the stack (`Heap.max_release_depth` leaves the rest to the collector); a struct in an object's field is now taken out while a changing method or setter runs, instead of a copy silently overwriting changes made meanwhile; assigning through a call gets a message saying to name the result first |
| 2 | Inheritance: construction order, `super`, overrides and abstract dispatch, defaults through overrides, the build-depth guard | Done: `super` from a middle class, in blocks, nested functions, captures, and through trait defaults all held, as did compound setters through `super`; taking a method from an object still being built is now allowed and checked when the taken method is called (`Interpreter.versionOf`/`requireVersionBuilt`); an override may give a present value where its base gives an optional of that type; `Sub.member` for a base class's type-level member says they are not inherited; the recursion error no longer nests backticks around a description such as "the constructor of X" |
| 3 | Type tests: `is` at runtime, narrowing through `and`/`or` and reassignment, `type_name` | Done: runtime `is` and `type_name` held for subclasses, traits, optionals, enums, nested tuples, and collections; narrowing held through `and`/`or`/`not`, `else`, loops, and reassignment. A block keeping a narrowing made outside it for a `var` assigned later crashed (for `is` and for `nothing` alike), so a captured variable that is ever reassigned now keeps its declared type inside a block (`Facts.reassigned`, `Checker.capturedAndReassigned` for the help); a type test on a field now says to copy the value into a `const` rather than to test it in place |
| 4 | Traits: conformance and conflicts, dispatch and value semantics through trait values, change inference, `Trait.method` | Done: conflicts (including diamonds, where the more specific trait's default wins), base class methods over trait defaults, value semantics and change inference through trait values, captured methods, and property requirements all held. Fixed: an implementation of a requirement called through its own type ignored the trait's parameter defaults (`declarationWithDefaults` now follows traits as dispatch does); taking `Trait.method` as a value crashed when called and is now rejected; a trait's private helper reached from a trait built on it or an adopting type said "has no method" and now says it is private to the trait (`reportTraitPrivate`) |
| 5 | `Self`, operators, and the prelude: substitution, adoption through classes, shadowing, captures | Done: operators on fields, list elements, and `+=` through places; chains evaluating each operand once; `Self` along class chains (a subclass re-adopting a trait keeps the first adopter's `Self`), in lists and tuples, and refused through trait values in every shape; the prelude shadowed per namespace through `using`; and capture checks through operators all held. Fixed: a trait's or enum's name written as a value said to construct it by calling the type (`reportTypeAsValue`) |
| 6 | Enums and `case`: coverage, flow analysis, runtime matching, the lexer's brace change | Done: coverage of enums, `Bool`, and `nothing`; completeness for returns, definite assignment, `break` and `continue`; subjectless narrowing; evaluating the subject once and alternatives only until a match; identity for objects; enums with `Ordered`, type-level members, keys, and sets; and multi-line blocks, `case`s, and set types inside parentheses all held. Fixed: `when 1.0` after `when 1` was not reported as a known duplicate (`knownAlternative` keys exact whole-number floats as `Int`s); assigning to an enum value through a value said "has no field" instead of that it belongs to the type |
| 7 | Diagnostics across all six slices, including items noted in earlier chunks | Done: fixed a set of an ineligible type reported twice, once from the annotation and once from checking `[]` against it (`typeOfSet` no longer repeats the check both construction sites already make); the dictionary key and set help now mention enum values; the member-not-found help inside an `if a is Dog { ... }` whose narrowing an assignment already undid no longer suggests writing that same test, and instead says the test no longer holds and why (`Checker.active_narrows`/`activeNarrowFor`); an operator's help for an optional right operand now says to check it against `nothing` or give it a fallback; a second, guessing operator error no longer cascades from a `with` list that already failed to resolve a name (`trait_list_errored`); and `examples/operators.em`'s `compare` no longer teaches the `self.cents - other.cents` idiom that overflows at the ends of `Int`, using `if`/`else` instead |

The third code review is complete: all seven chunks are done, each with small adversarial
programs run in both Debug and ReleaseSafe, a conformance case for every confirmed problem,
and the spec updated wherever the fix was a design decision rather than a plain bug.

## Next concrete step

Section 20's first 13 vertical slices are complete. Slice 14's focused `Int`, `Float`,
String, List value-transform, filtering, traversal, predicate-question, while-portion,
endpoint-property, flat-map, filter-map, sum, and String-representation parts are complete.
The next standard-library part should consider numeric List `average`, applying the same
optional empty-List result rule; `Iterable` and the advanced String operations listed below
remain deferred rather than incomplete work in this slice.

The user chose to begin slice 15 instead. The formatter is complete through its
adversarial review: struct, class, trait, and enum declarations and their members,
`case`/`when`, `try`/`catch`/`finally`, `raise`, `assert`, tuples, destructuring,
dictionaries, sets, list literals, lambdas, `is`, qualified names/`using`, optional and
function types, and every literal form each held up under small, adversarial `.em`
programs in Debug and ReleaseSafe; the review's own two findings — a trailing-block
call's parentheses needing to survive in an `if`/`while`/`for`/`case` header — are fixed
and guarded. See "Formatter decisions worth knowing" above.

The REPL is also complete: `emerald repl` keeps declarations and values across entries,
prints a bare expression's value, and clears with `:reset`, all manually verified
interactively (a `var`/`const` declaration read back later; reassigning a `var` and
rejecting a `const` reassignment or a redeclaration; a bare expression and an ordinary
call statement, side by side; a multi-line `{`/`(`/`[`/block-comment/triple-quoted-string
entry; a genuine syntax error not affecting later entries; an uncaught runtime error
followed by the session continuing normally; two sequential `input()` calls across
separate entries, replaying correctly on a later turn; `:reset`; a clean Ctrl-D exit); see
"REPL decisions worth knowing" above.

The LSP's first slice is also complete: `emerald lsp` serves live diagnostics, document
symbols, and format on save over JSON-RPC/stdio, manually verified end to end by piping
hand-framed messages through it (see "LSP decisions worth knowing" above for the full
list of what was checked). Hover, go to definition, find references, safe rename, and
completion remain for a second LSP slice, each needing real new infrastructure this one
deliberately did not build — see the same section for exactly what each needs. A VS Code
extension (a separate, thin client talking this same protocol, per the earlier
discussion on repository conventions) has not been started. Nothing further is queued
specifically for the formatter or the REPL.

Slice 16 is queued as one test-infrastructure and hardening pass: CI for Debug and
ReleaseSafe with the pinned Zig version, allocator-failure testing, lexer/parser fuzzing,
automated full Unicode conformance, Linux/macOS/Windows coverage, focused tests for
subsystem invariants that end-to-end cases do not localize well, and broader combinations
of error handling and test discovery across inheritance and project files. New slices still
add their own behavioral tests as they land; this backlog slice strengthens the suite as a
whole.

Section 7 remains complete apart from capturing built-in methods, which the user has put
off. Deferred language features in section 21 remain deferred.

## Validation and blockers

- The LSP's first slice (slice 15) was checked in Debug and ReleaseSafe: `zig build test`
  passes both, including `Lsp.zig`'s own unit tests (wired in as `emerald-lsp`, following
  `Repl.zig`'s `repl_module` pattern). Every handler was also exercised by piping
  hand-framed JSON-RPC messages into `emerald lsp` directly and inspecting the raw framed
  responses: the `initialize` handshake and capabilities; live diagnostics on both a valid
  and a broken document, and `didChange` correctly re-checking and clearing a diagnostic
  once the text was fixed; document symbols against a struct (field, constructor,
  method), an enum (a value), and a trait (a property requirement); formatting on both
  parseable text and text the parser rejects (an empty edit list, per 18.3's refusal
  rule); a string-typed request id round-tripping unchanged; an unsupported method
  correctly answered "method not found" rather than crashing or hanging; a query against
  a URI that was never opened returning an empty result; and the UTF-16 position
  conversion against a plain ASCII case, an accented BMP scalar, and an actual astral
  emoji, each producing the exact expected column, surrogate pair included.
- The REPL (slice 15) was checked in Debug and ReleaseSafe: `zig build test` passes both,
  including `Repl.zig`'s own unit tests for the completeness heuristic (wired in as
  `repl_module`/`emerald-repl` in `build.zig`, since module-based test discovery does not
  walk into `main.zig`'s own `@import`s on its own). Beyond the suite, every scenario in
  this slice's plan was driven manually through piped stdin scripts, listed in "Next
  concrete step" above. One real bug was caught only this way: the replay reader's first
  version could silently drain far more of the shared stdin stream than one `input()`
  call actually needed, stranding the surplus in a buffer discarded at the end of that
  turn and permanently losing it from the one shared reader every later prompt and
  `input()` call depends on — the symptom was a session that quietly ended, as if Ctrl-D
  had been pressed, right after any entry that called `input()`.
- The formatter (slice 15) was checked in Debug and ReleaseSafe: `zig build test` passes
  both, including `Formatter.zig`'s own unit tests (blank-line collapsing, a same-line
  trailing comment, a block comment's verbatim interior, both parenthesization cases
  below, the call-versus-literal trailing-comma difference, and a self-format no-op), the
  `conformance/format/` cases (including one added by the adversarial review), and CLI
  contract tests for `format` and `format --check`. Beyond the suite: every file under
  `examples/` round-trips byte for byte; formatting every file under `conformance/` (407
  files total) neither crashes nor needs a second pass to reach a fixed point; and running
  every `conformance/run/` program before and after formatting it prints identically. Three
  real bugs were caught only this way, not by any unit test written in advance: `(dx * dx +
  dy * dy) ** 0.5` losing its parentheses (and its meaning) in `examples/structs.em`; a
  trailing comma the printer added after a multi-line call's last argument, which
  `Parser.finishCall`'s grammar (unlike a list literal's) does not accept, in
  `conformance/run/lists.em`; and, found by the review chunk that deliberately attacked
  every remaining construct with small adversarial programs rather than only the existing
  corpus, a trailing-block call losing its disambiguating parentheses in an `if`/`while`
  condition, a `for`'s iterable, or a `case` subject, at any nesting depth — in each case
  producing formatted output that failed to parse at all, confirmed by reformatting the
  fix's own conformance case with the fix disabled and watching the second pass fail.
- Writing this slice found a bug that only a ReleaseSafe run could find. `check` and `run`
  wrap their one file in a `Project`, and the first version built it with `&.{ ... }`,
  which is a pointer to a temporary that dies at the return. Debug passed every test;
  ReleaseSafe crashed 142 of them. The one-file array is now a local of the caller, which
  outlives the call it is passed to. Run both modes before believing a green suite.
- `zig build test` passes in Debug and ReleaseSafe after the `Float` implementation: 314
  unit tests, 333 conformance cases,
  and 10 command-line contract tests. The new cases cover typed and untyped catches, built-in
  runtime errors, bare re-raise, cleanup through return, loop control, and failure,
  secondary failures from cleanup, assertion operand reporting, mutation before a raised
  error, catch types reached through a namespace alias, repeated access after caught module
  and type setup errors, test
  failure isolation, status 3, skipped entry statements, and per-binding lazy entry
  initialization in test mode.
- The chunked review of the struct slices (see "Code review of the struct slices") confirmed
  every fix non-vacuous the same way: each new conformance case fails with its fix
  disabled, in a build that still compiles, and passes once the fix is restored. Fixes on a
  path every call, assignment, or member access runs were timed against the previous commit
  in ReleaseSafe.
- The field-assignment slice's own copy-on-write unit test was confirmed non-vacuous:
  disabling `Heap.uniqueStruct`'s copy (forcing it to always return the shared instance)
  fails both that test and `run/struct-field-assignment`, and both pass again once it is
  restored. Checked in Debug and ReleaseSafe.
- An adversarial review of the field-assignment slice, run against its diff before it was committed, found
  two real regressions (the duplicate diagnostic and the qualified-receiver crash, both
  described above) and one pre-existing crash the diff made easier to reach (the missing
  `reach` calls). All three were reproduced by running the program, not only by reading the
  diff, and each now has its own conformance case so it cannot come back silently.
- Every host-stack probe — 100,000 nested parentheses, 100,000 prefix minuses, a
  1,000,000-term flat sum, unbounded recursion, and 1,000 calls at 250 levels of nesting —
  ends in the right answer or a clean diagnostic, identically in Debug and ReleaseSafe.
- `conformance/diagnostics/definite-assignment.expected` reproduces the canonical diagnostic
  printed in section 17.1 character for character, apart from the path and position.
- Writing this slice found a leak worth remembering. Returning a struct that owns an
  `ArenaAllocator` by value copies the arena, and the copy snapshots the list of blocks it
  owns. Allocating into the arena inside the same struct literal that copies it therefore
  strands that allocation in the dead local. Finish every allocation before constructing
  the result; `analyze` and `Parser.parse` both do this deliberately.
- Writing the conformance suite immediately found a real defect. The standard streams were
  opened in positional mode, which starts at offset zero, so with output redirected to a
  file each diagnostic overwrote the one before it and only the last survived. Standard
  streams now use `writerStreaming`. Note that the defect is invisible when output goes to a
  terminal or a pipe, which is why the command-line contract tests did not catch it; the
  guard against a regression is the comment in `writeAll` plus the two-diagnostic
  command-line case, which at least proves both diagnostics are emitted.
- `bash tools/check-toolchain.sh` passes.
- Verified against the pinned standard library: `std.unicode` provides UTF-8/UTF-16
  encoding, decoding, validation, and code-point counting only — no grapheme segmentation
  and no normalization. Emerald must vendor UAX #29 and UAX #15 tables for grapheme
  indexing (9.1) and normalized equality (9.2). This is recorded in 19.1 and should be
  planned into the string slice, not discovered during it. `std.fmt` does provide
  shortest-round-trip float formatting, satisfying 9.4.
- Zig 0.16 API notes worth not rediscovering: `zig env` emits ZON rather than JSON;
  `std.fs` is deprecated in favor of `std.Io.Dir`; `std.process.argsAlloc` is gone and
  `main` instead takes a `std.process.Init` supplying the allocator, `Io`, and arguments;
  `addExecutable` and `addTest` take a `root_module` built by `b.createModule`.

### Deferred

- From the object model review: assignment through a call's result, as in
  `find().score += 1`. Changing methods already work on a temporary, but assignment is
  checked from a named root; `const found = find()` first is the way to write it.
- Displaying more than 256 objects nested inside one another shows the innermost as
  `Name(...)`, the same notation as a cycle, since the display stack is fixed.

- From section 7.1: a call inside a block written at module level is not checked against
  module variables not yet assigned, since the block may run later; the runtime reports
  the read as unassigned (found in the third review, chunk 5).
- From section 11.2: taking `Trait.method` as a value (rejected with a message for now).
- From section 4.4: the warning for a type test whose answer is known before the program
  runs, which needs diagnostics with a severity.

- From section 7: capturing a built-in method such as `numbers.append` (7.4 says every
  method is capturable, with an expected type for `numbers.map`; the user plans it for
  later), variadics (already deferred in the spec), and capturing a built-in function such
  as `print`, which no written function type describes. A top-level `return`, which
  section 14.1 uses to end the program, is rejected outside a function for now.
- Section 14.1's warning for unreachable code after a `return`. Diagnostics have no
  severity yet; until they do, code after two branches that both return is treated as
  assigned everything rather than reported.
- Section 6.2's `if ... then ... else` expression. `unless` is no longer part of the language
  and is not a keyword.
- From section 8: the rest of section 8.6's rich vocabulary beyond `each`, `map`, `find`,
  and `find_index`, and slicing with ranges.
- Range values: ranges and counts stored in names, `random(1..6)`, and the block forms of
  `up_to`, `down_to`, and `times` are rejected ("a range can only be looped over so far")
  until range values land. Blocks now exist, so only the range value itself is missing. In a
  `for` header every counting form works.
- Section 4.5's optional chaining, `?.`. It exists to shorten chains through objects, and
  there are no object fields or properties to chain through yet; the parser reports it and
  points at narrowing and `.or(...)`.
- From section 9: `letter?` and `digit?` (general category tables) and string slicing with
  ranges. `words`, `title_case`, and case-insensitive Unicode comparison also need a
  dedicated locale and boundary design pass.

### Review findings still open

Six subagents ran an adversarial review of `7214005^..ed868a4` (the fieldless struct
foundation and required-fields slices) before this handoff was next touched. Four of the
six independently found the qualified-receiver bug fixed in `1850085`. The private-name,
module-initialization, and recursively hidden NaN defects found in the same review are fixed
in `72e7df4`. The chunked review of the struct slices later retired the
argument-checking duplication this list used to include. The remaining items are
maintainability work rather than reproduced behavioral failures:

- **Struct field lookup is hand-written twice instead of resolved once.** `evaluateProperty`
  (`Interpreter.zig`) and `typeOfMember` (`Checker.zig`) each independently scan
  `descriptor.fields`/`user.fields` by name with their own `std.mem.eql` loop. A tuple
  position is resolved once, by the parser, into a numeric `Member.position`; a qualified
  name is resolved once, by the resolver, into `Facts.qualified`. A struct field never got
  the same treatment, so correctness depends on the checker's scan and the interpreter's
  scans (`fieldPosition`, used by reads, stores, and `containerSlot`) agreeing by
  construction rather than by sharing one answer. Since properties arrived, a name the
  interpreter's scan misses is read as a property, so a divergence (case sensitivity,
  Unicode normalization) would now fail on a missing property rather than an `unreachable`.
  Worth resolving a member to its field position or accessor once, before the object model
  grows further.
- **Struct equality duplicates the tuple/list sequence-equality pattern.** The new
  `.struct_value` case in `Value.equals` — descriptor-identity check, then a paired loop
  calling `equals` recursively and stopping at the first mismatch — is structurally identical
  to the `.tuple` case immediately above it, and to `.list`'s. A small `equalsSequence(gpa,
  a, b)` helper would remove the third copy.
- **Struct field parsing duplicates parameter parsing.** `parseParameter` parses "name →
  require `:` → `parseTypeExpression()` → optional `= default`", and `parseStructMember`
  repeats the same sequence by hand for a stored field, with its own messages. Defaults
  arrived for both at once, so they have not diverged yet, but a change to one (a new
  annotation form, say) has to be made twice.
- **Every parsed type annotation now allocates, even without a namespace path.**
  `parseTypeExpression` used to return a zero-copy slice straight from source text in the
  common case (`Int`, `String`, an element type with no `.`). This slice's qualified-path
  handling unconditionally builds an `ArrayList(u8)` and copies the name into it before
  checking whether a `.` ever follows, so every parameter, return type, variable annotation,
  and now every struct field pays an allocation it did not need before. Start the list only
  once a `.` is actually seen.
- **`check()` scans every statement four times to find struct declarations.** Four separate
  `for (programs) |program| for (program.statements) |statement|` loops each refilter
  `statement.data == .struct_declaration` — for identity and hoisting, field resolution,
  dictionary-key eligibility, and the final pass over bodies. Collecting matches into a flat
  list on the first pass and iterating that list afterwards would filter once.

### Known rough edges

- Interpreter-detected failures currently use the common `RuntimeError` type. Grow the
  hierarchy with the feature that produces each failure instead of designing it all at
  once. The first existing requirements to reconcile are `RecursionError` in section 7.2
  and `InputError` in sections 2 and 15.2; later conversion, filesystem, regex, and network
  work should add its specific error types in the same implementation slice.

- **A literal mixing sibling classes needs its type written.** `[Dog(), Cat()]` is reported
  as a list holding `Dog`, since inference never looks for a common base class; `const pets:
  [Animal] = [Dog(), Cat()]` works. A common-base rule would need designing with `if`
  branches and `or`, which infer the same way.

- **What a block assigns is recorded by bare name.** `Facts.assigned_in_lambda` holds names,
  not bindings, so a lambda or nested function assigning its own `text` stops narrowing of
  every `text` in the program, and changes that one's help to say a block could set it back.
  Conservative, never unsound; found in review chunk 6.

- **A long chain of calls between top-level functions is slow to check.** 2,000 functions
  each calling the next take about 2 s in ReleaseSafe, before and after the section 7 slice.
  Found in review chunk 1; the checker's walks over the call graph are the likely cause.

- Assigning to a type-level field through its namespace, `Shapes.Circle.made = 1`, is
  reported as "`Shapes` is a namespace, not a value"; reading and calling through the
  namespace work, and `using Shapes` then `Circle.made = 1` works. Assignment through a
  namespace was never supported for module bindings either, so the two should be lifted
  together.
- The capture check over-approximates type setup: constructing a type counts what every
  type-level field's value reads even after the type is set up, and reading one field
  counts all of them. Moving the use below the assignment always works.

- The capture check counts what a default reads even when the call supplies that argument,
  so `Box(width: 2)` above the assignment of a module variable only `width`'s default reads
  is reported. Moving the call down always works. Tracking default reads separately, per
  parameter, would remove the false report.

- Reaching a receiver while its changing method runs is caught only at runtime. The common
  case — the method, or a function it calls, reads the module variable it was called on — is
  visible to the capture facts and could become a `check` diagnostic.

- `invoke` restores a changing receiver and releases its inputs for every Emerald error and
  for the recursion limit. A host allocation failure while it is still constructing the
  call frame can leave some argument counts high until the interpreter heap is torn down.
  Host allocation failure stops the run and cannot be caught by Emerald, so this is not
  observable language behavior, but the ownership path should be made fully transactional
  when allocator-failure testing is added.

- Recursive dictionary-key eligibility currently keeps a fixed path of 256 struct types.
  A cycle is correctly rejected, but an acyclic chain deeper than 256 is conservatively
  rejected too. Ordinary programs will not approach this; replace it with checker-owned
  visitation state if generated code ever does.
- The capture check is conservative. It flags a call if the callee could read an
  unassigned variable on any path, even one this particular call cannot take. Moving the
  call below the variable is always the fix, and the diagnostic says so.
- Definite assignment at the top level does not see assignments made inside a called
  function. `var total: Int`, then a call to a function that sets it, then a read, is
  rejected as possibly unassigned. Initializing the variable is the fix.
- A diagnostic that quotes a line containing invalid UTF-8 prints the offending bytes raw,
  so a terminal shows a replacement glyph. Escaping them is a small refinement worth doing
  when the lexer starts reporting byte-level problems more often.
- `emerald check` on a missing file exits `64`. Section 18.1 does not cover that case; `64`
  was chosen because there is no source to diagnose. Confirm or change deliberately.
- Indexing a string by character is linear, as section 9.1 accepts, so
  `for i in 0..<s.count { s[i] }` is quadratic. `for character in s` is the linear way, and
  a cached boundary index is the fix if real programs need it.
- A string's searching methods return text built from the normalized haystack when the
  haystack was not already NFC, so `replace` on decomposed text yields composed text.
  Canonically this is the same string, but the bytes differ from the input.
- A multi-line block comment joins the lines around it rather than terminating a statement,
  matching how C-family languages treat their block comments.
- Closures in a loop no longer grow memory. The same measurement that showed 155 MB for
  200,000 iterations of `const block = { => i }` before the collector now shows 3.4 MB, and
  the program got faster rather than slower (0.09 s against 0.17 s) because it allocates
  less. The threshold is 4,096 live objects, doubling to twice the surviving count after
  each collection.
- Removing an entry from a dictionary or set rebuilds its index table, so removing many
  entries one at a time is quadratic in the size of the collection. Insertion order is
  what makes this the simple choice — the entries are an array, so a removal shifts every
  later one. A tombstone scheme would fix it if a real program ever notices.
- Narrowing does not cross `or`. `if value == nothing or score > value` is rejected, while
  the same test written as `if`/`else` is accepted. Section 4.5's narrowing is applied to
  branches and loop bodies but not to the right operand of a short-circuiting operator,
  where the left operand's falsity is also a proof. The diagnostic it produces is worse than
  the gap: it says "`>` needs numbers, but these are Int values", which names the payload
  type rather than the optional. Found while writing `examples/project/`, and predates this
  slice.
- The capture check does not follow a function reached through a value. `const f = later`
  then `f()` above a module variable `later` reads is not reported the way a direct call is;
  the interpreter's unassigned-read error catches it at runtime instead. Extending
  `checkCaptures` to callable values would need the checker to track which function a
  variable holds.
