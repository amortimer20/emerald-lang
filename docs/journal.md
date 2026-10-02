# Emerald engineering journal

This is an append-only historical record: completed-slice narrative, past validation runs,
and non-obvious lessons learned, retired here once `docs/handoff.md`'s "Current milestone"
moves on. Entries are never edited after the fact — correct forward from here, the way a new
commit corrects old code, rather than rewriting history. `docs/handoff.md` is the live status
a session starts from; this file is where its completed chapters go so it doesn't grow
without bound. Durable language design lives in `docs/rewrite-context.md`, not here — an
entry below may explain *why* a decision was made, but the decision itself is recorded there.

Sections are in roughly the order the work happened, oldest first.

## Console widgets: column width

The first tables/panels/prompts slice adds terminal column measurement to the Unicode 17.0.0
tables, including East Asian Wide/Fullwidth and emoji presentation data. The width function
walks graphemes and ignores complete SGR sequences using the same recognizer as
`Console.plain`. `Console._width` exposes it privately to the prelude's coming layout code.
Unicode conformance found 0 failures across 20,034 cases and 1,094,978 unlisted code points.

## Console widgets: panels and text tables

The second slice builds `Console.panel` and `Console.table` for text rows in Emerald. They
measure through the private Unicode width native, preserve styled cell text, and make exact
Unicode borders. Conformance covers nesting, titles, multiline text, empty/header-only
tables, CJK and emoji widths, forced color, and the error messages for malformed rows and
cells.

## Console widgets: struct tables

The third slice accepts a List of plain records, using CSV's existing checker rule for
text-compatible fields and the same runtime conversion of public fields to cells. The
prelude's table layout handles both row shapes; numeric struct columns align right.
Conformance covers mixed numeric/optional values, private-field omission, empty typed
records, invalid fields, and rejection of an explicit header with struct rows.

## Console widgets: prompts

The fourth slice adds `InputError` and the six line-oriented prompts in the prelude. `input`
now raises the specified subclass for end-of-input and invalid UTF-8, while `input_maybe`
retains its optional EOF behavior. Prompts validate and retry with the plan's messages,
support defaults and numeric bounds, and return multi-selections in option order after
ignoring repeated indexes. Conformance feeds scripted answers end to end and catches
`InputError`.

## Console widgets: integration

The fifth slice completes the Console milestone's documentation and status updates. The
official example now combines styling, a struct table, a panel, and prompts with defaults so
the documentation smoke test remains non-interactive. The fuzz generator also exercises the
ordinary text-row table and panel paths. The accepted Console design is now reflected in the
rewrite context and library inventory.

## Base64, hashing, and hexadecimal

The four-slice utilities milestone is complete. `Bytes` now has lowercase hexadecimal
conversion, Base64 supports standard and URL-safe forms, and `Digest` exposes SHA-256 and
HMAC-SHA256. Invalid encoding is consistently `EncodingError`; native arguments are bound by
name. The final integration added separate reference pages, a runnable local example, prelude
reachability coverage, and fuzz templates. Differential tools covered 2,000 Base64 outputs
(1,000 cases, seed 1) and 2,000 digest outputs (1,000 cases, seed 1), both with zero
differences from Python.

## HTTP native transport slice

The first HTTP slice added `src/Http.zig`, with no Emerald-facing declarations yet. Its local
Zig test server binds only `127.0.0.1` on an ephemeral port and scripts success, POST/header/body
echoing, error status, redirects and a loop, gzip, chunked data, a large body, binary data, and
a slow response; automatic tests never contact the internet. The interpreter's
`std.Io.Threaded.global_single_threaded` explicitly cannot run concurrent or cancellable work,
which a direct test confirmed. `Http.Client` therefore owns a worker-backed `Io.Threaded` and
races each request against `Io.sleep` on Zig 0.16's monotonic `.awake` clock, cancelling and
joining the loser before returning. This is the plan's first timeout fallback, selected before
any Emerald API could depend on an unbounded request.

## Operator-annotation design and implementation

The extended operator-design discussion was retired from the live handoff once implementation
began. Its accepted outcome is recorded normatively in rewrite-context §11.5 and §22:
annotation-registered user arithmetic replaces the former `Addable`, `Subtractable`,
`Multipliable`, and `Divisible` authorization traits; `Ordered` remains the trait-backed
comparison contract. Commits `d73ede4` and `f2dfac2` delivered the parser/runtime and
selection/compound-assignment slices respectively. The retirement and migration slice follows
in the next commit.

The follow-up LSP slice made arithmetic symbols themselves navigable. `Ast.Expression.Binary`
now stores the source span of its operator token; the checker already records the selected
annotated method key, so `textDocument/definition` can map a cursor on the token directly to
that method without rerunning or dynamically reselecting dispatch. This intentionally does
not make symbols renameable: the method name remains the declaration programmers rename.
The same key now makes a method's find-references result include the operator token as well as
ordinary named calls.
Rename keeps its identifier contract: it rejects a cursor on an operator token and omits such
reference locations when renaming the registered method.

## Versioned binaries

Development builds now embed and report `Emerald 0.4.0-dev` through `emerald --version`. The
release workflow derives a distributed binary's value from the pushed `vX.Y.Z` tag, passes
it as a build option, and smoke-tests the packaged executable's exact output. The normal help
banner stays version-free so discovery remains about what a command can do.

## First diagnostic explainer

`emerald explain <code>` now turns four common checking problems into a short,
before-and-after teaching example. The command owns no persistent history: each CLI invocation
is independent, so bare `emerald explain` stays deferred instead of guessing at a
previous terminal session. The normal CLI renderer labels only the curated diagnostics with
their stable codes—undefined name, declaration type mismatch, const reassignment, and unknown
member—while the conformance and editor renderers retain their existing prose-only shape until
they deliberately adopt diagnostic codes themselves.

## Command-contract QA and interaction polish

The CLI suite gained direct tests for the boundary between `check` and `run`: checking a valid
program never runs its entry code, a source error stops `run` before entry execution, and a
warning remains visible and yields status `1` even when `run` executes successfully. It also
covers `--` arguments for both `run` and `test`, plus invalid `repl` and `lsp` invocations.
Existing CLI cases already cover command usage, missing files, runtime errors, test failures,
and formatter write/check behavior.

The follow-up made the terminal contract discoverable rather than treating every situation as
one generic usage error. Bare `emerald` and `--help` now show short global help; `help <command>`
and `<command> --help` carry the details, while unknown or malformed invocations identify the
mistake and point to the relevant help. The editor-only LSP endpoint stays available but is not
advertised in that discovery list. `check` no longer accepts `--` arguments it would silently
discard. Formatter checks name files that would change and a formatting run reports actual
rewrites; a clean formatting run stays quiet. The REPL now offers the three small terminal
commands beginners need: `:help`, `:reset`, and `:quit`.

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

## Slice 14 and the object model: standard-library vocabulary, structs, classes, traits, enums, errors

The paragraphs below are section 20's slice narrative as it was written turn by turn while
each part landed — kept verbatim as the historical record of what shipped when, even though
`docs/language/` and `docs/library/` now describe the same behavior more completely and are
the pages to trust for current details.
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

Slice 14 (now complete). Part 1 adds the settled `Int` vocabulary: `abs`, `clamp`,
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
`Float.nan` expose the two special values. The next receiver-only additions continue the
same family with `square_root`, `to_radians`, and `to_degrees`, matching the rewrite
context's single-value method split before the broader `Math` namespace work. Rounding-to-Int
checks finiteness and the exact asymmetric bounds before invoking Zig's conversion.
`round_to` accepts positive and negative decimal places, ties away from zero, and defines
its behavior beyond binary64's decimal range. Float method arguments perform Emerald's
ordinary `Int` widening at runtime as well as in the checker. A conformance case now reaches
section 8.3's NaN-key guard through strict string conversion, retiring the stale claim that
no Emerald program could produce NaN.

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

Part 5 adds `filter` and `reject` to Lists, Dictionaries, and Sets. Both use an eager
`func(Element): Bool` predicate, run it once per item in input order, and return a new
receiver-kind-preserving collection without changing the receiver. `filter` retains accepted
items and `reject` retains rejected ones. Dictionary predicates receive one destructurable
`(key, value)` tuple; Set predicates receive their member. The existing higher-order call path
therefore supplies ordinary closure captures, nested patterns, errors, and stack traces
without a second callback implementation. Dedicated conformance covers order, callback
count, unchanged inputs, result kind, predicate types, and missing blocks.

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

Part 12 adds String `code_points()` and `bytes()`. Both return `List[Int]`: the former gives the
Unicode scalar values of the stored spelling, while the latter gives its exact UTF-8 octets.
They deliberately expose advanced representation details without introducing a premature
`Byte` type; `chars()` remains the grapheme-aware operation for ordinary text. Conformance
covers an accent written with a combining mark and an emoji, plus the two UTF-8 bytes of `é`.

Part 13 adds List `filter_map`. Its block returns one optional value for each input item;
present values enter a new List in input order and `nothing` is omitted. It does not flatten:
a block returning `List[Int]?` produces `List[List[Int]]`. The checker requires an optional result and
directs an always-present block toward `map`; the evaluator retains a present result directly
and releases `nothing`. Conformance covers callback count, unchanged input, empty input,
nested List results, a non-optional block, and a missing block. Dictionary and Set forms stay
deferred.

Part 14 adds List `sum()` for `List[Int]` and `List[Float]`. It returns the matching numeric type,
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

Part 16 adds List `average()` for `List[Int]` and `List[Float]`. It returns `Float?`, because a
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

Part 20 adds List `sort`, `sort!`, `sort_by`, and `unique_by`, plus `associate`,
`associate_by`, and `to_dictionary`. Sorting uses the same order contracts as the extrema and
is stable; keyed callbacks run once per item from left to right; `sort` and `sort_by` reject
NaN at runtime. Keyed uniqueness keeps the first item per key. Dictionary construction keeps
the first insertion position and the last value for a repeated key. Conformance covers value
and in-place sorting, stable keyed ordering, custom `Ordered` values, empty Lists, duplicate
keys, static misuse, const mutation, and NaN failures.

The next focused standard-library part should be selected from the remaining section 8.6
vocabulary. List ordering, keyed uniqueness, sequence-to-dictionary construction, and the
randomness-dependent shuffle family are complete in this slice.

Part 21 adds the `exit` prelude function. `exit()` requests status `0`, while `exit(code)`
accepts an `Int` from `0` through `255`. It is control flow rather than a typed error: it is
not catchable, but every pending `finally` executes before it reaches the program boundary.
Conformance covers the cleanup order, static misuse, an invalid runtime status, and the API's
requested-status report.

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
and sets work: `Dict[String, Int]` and `Set[String]`, their literals, bracket lookup producing an
optional, bracket assignment, insertion order, equality by contents rather than order, and
the essential vocabulary of 8.5. Memory is
managed: reference counting reclaims promptly
and section 19.5's mark-and-sweep collector reclaims the cycles counting cannot, so a loop
that keeps making blocks runs in flat memory. Every expression has a static type before
execution and
definite assignment is proved through control flow. Failures that cannot be known
statically travel as typed Emerald errors and may be handled by the program.

## Implementation decisions worth knowing

Non-obvious bugs, false starts, and design rationale found while building each slice —
useful for not rediscovering the same lesson twice, even though the feature itself is long
since complete and documented.

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
  Placement stays structural: the flag on a list is `List[String]?`, the same flag on its
  element is `List[String?]`.
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
- **A buffer records its element kind**, because runtime has no static types but a `List[Float]`
  must store `rates.append(2)` as `2.0`. List literals get their element type from the
  checker's `literal_types` table, which is how `var rates: List[Float] = [1, 2]` stores
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
  the same section relies on it to infer `List[Float]` for `[1, 2.5]`, which is not arithmetic.
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

## Slice 15 completion (formatter, REPL, LSP)

Slice 16 (test-infrastructure and hardening) and the LSP's second slice (hover, go to
definition, find references, safe rename, completion) were still queued, not started, when
this was written; check `docs/handoff.md`'s current status for whether that's changed.

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

## Validation history

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

## Handoff consolidation, 2026-09-20

The live handoff had accumulated completed-slice prose despite the journal split. Its stale
"Slice 16 queued" account was already corrected by the hardening commits; this consolidation
retired the remaining narrative from the live starting point and left a concise status,
next-step, rough-edge, and validation record there.

Since the prior journal entries, `6fca3c8` added String/List range slicing and bounded
execution to the fuzz runner; `6a6a718` retired the five object-model maintainability review
findings; `9aea23d` through `37cddef` shipped and completed the whole-file `File`,
`Directory`, and `Path` library area, including `FileError`, documentation, and failure
coverage; and `f671b1f` added the conservative always-false `is` warning for unrelated
classes. The latter intentionally excludes traits, because a subclass may adopt a trait its
base class does not.

## Ledger shakedown, 2026-09-20

The roadmap's first remaining item became [`examples/ledger/`](../examples/ledger/): a
two-file, persisted personal-finance command-line project. Its `add`, `list`, `summary`, and
`category` commands store a tab-delimited journal under `.emerald-ledger/` in the working
directory. It deliberately keeps dates as lightly validated `YYYY-MM-DD` strings rather than
turning the example into a date-time or serialization design pass.

The program exercised `Program.arguments`, multi-file project loading, `File`, `Directory`,
and `Path`; structs through `Textual`; `List`/`Dict` transforms; numeric formatting; optional
parsing; and a program-defined `LedgerError`. Full add/list/summary/category persistence plus
empty-store and invalid-input paths ran against the built binary. The only issue discovered
was an ordinary authoring error — the predicate is `starts_with?`, not `starts_with` — so the
shakedown adds no new language backlog item. The next recommended work is the LSP's second
slice.

This consolidation's first pass over-trimmed: it dropped five still-true "Deferred" items
(`remove_if`, `Trait.method` as a value, bare top-level `return`/`Program.arguments`,
capturing a built-in function or method plus variadics generally, and a module-level
lambda's declaration-site-vs-call-site capture check) without re-verifying they'd actually
been resolved. None had been — each was re-checked directly against the binary before
restoring them to a "Deferred" section in the live handoff. The lesson: "no longer current"
has to be confirmed per item before a section is retired, not inferred from how much other,
genuinely-resolved work landed in the same pass.

## Numeric formatting and `Textual`, 2026-09-20

Two 15.5/15.1 slices that had been described as design intent for a long time, built in
that order because the second depends on nothing from the first but reads better after it.

`Int.to_string(base:)` and `Int`/`Float` `format(...)` landed first. The interesting part
was not the formatting but the argument shape: these are the first built-in methods with
real named, defaulted arguments, and `typeOfMethodCall` had a blanket rejection of named
arguments for anything whose receiver is not a struct, on the reasoning that a built-in has
no declared parameters to match. That rejection now carves out these two names and routes
them through `checkArguments`/`evaluateBound`, the same machinery a declared function's
call uses, rather than growing a parallel one. A pre-existing conformance case asserted
that `3.to_string(base: 2)` was rejected; it was rewritten around a list method, since the
assertion it made is no longer true of the language.

`Textual` then landed as the sixth prelude trait in 11.5's family rather than as new
display machinery, which is what made it small. The decisive observation was that the
question "trait or inherited-from-`Object` method" was already answered in 4.4: `type_name`
is universal without implying a common root, so a universal behavior with a per-type
override point is an established pattern here, and `Addable`/`Ordered` already show what
"a prelude trait whose method built-in machinery runs" looks like. Explicit adoption, the
runtime descriptor check, trait-default and override resolution, and the "ran before this
was built" guard all came from existing mechanisms unchanged.

The one genuinely new piece of engineering was reaching user code from `Value.write`, which
is pure, recursive, and cannot import the interpreter. It became `writeThrough`, taking a
comptime context that is either `{}` or something with a `writeTextual` method; Zig infers
the error set per instantiation, so the interpreter's raises propagate with no out-of-band
smuggling and the `{}` path compiles to what was there before. Threading the context
through the recursion is what makes an adopting value render the same nested in a list as
it does alone, which was the design question worth settling before writing any of it.

Two smaller things fell out. `print` now builds its whole line before writing any of it:
its doc comment already promised no half-line on failure, and a `to_string()` that raises
is a new way to break that promise. And diagnostics deliberately stay on the field-based
form, so assembling an assertion failure never runs a program's own code — the debug form
is also the more useful one there. The checker warns when a type declares `to_string`
without adopting the trait, which is where someone arriving from C# or Java lands.

## The program entry point, 2026-09-20

14.1's two remaining pieces — `Program.arguments` and a bare top-level `return` — were the
roadmap review's first item, small enough to do as one slice once `exit(code)` turned out to
already be complete (nothing to do there beyond confirming it against the binary).

`Program.arguments` followed `Float.infinity`/`Math.pi`'s existing pattern for a type-level
constant that is not a user declaration: a key the resolver's `qualify()` recognizes
(`Program.arguments`), a fixed type the checker returns for it, and a value the interpreter
builds on read. The one new plumbing was getting the CLI's actual argv into that read: a
`Streams.arguments` field, defaulted to `&.{}` so every existing call site (tests, the REPL,
the fuzz runner) kept compiling unchanged, threaded through to `Interpreter.run` and read
fresh into a new `List` on every access — a shared cached list would have let one caller's
mutation leak into another's, which copy-on-write value semantics don't allow anywhere else.
`main.zig` gained `-- <program-argument>...` after the file path, accepted by all of
`check`/`run`/`test` alike so one parsing rule covers all three, though only `run`/`test`
populate the list.

The top-level `return` turned out to need less than expected: the resolver already rejects
any executable statement outside the entry file's top level (`checkModuleFile`'s "this would
never run"), so by the time `Checker.checkReturn` ever sees a `return` with `in_function`
false, the entry file's top level is the only place it can be — no new state to track, only
`self.files[self.file].entry` added for a self-documenting, non-inferred check rather than
leaning on that reasoning implicitly. The interpreter side was a one-line change: `run`'s
final `catch` had `error.Returned => unreachable` with a comment naming this exact feature as
the reason it could never fire; removing the `unreachable` and treating it like reaching the
end of the file was the entire fix, since `finally` unwinding was already shared with an
ordinary function return.

One pre-existing unit test encoded the old rejection as its expectation
(`"print(1)\nreturn\n"` expecting `` `return` can only be used inside a function ``) and
needed updating to the new behavior rather than being a regression.

## Trait-aware impossible type tests, 2026-09-20

`f671b1f` already warned when two unrelated classes make an `is` test false. This follow-up
extends that proof to a class tested against a trait: the checker scans the class and every
declared subclass, warning only when none adopts the target trait. A subclass adopting the
trait suppresses the warning, so the check remains sound for the runtime object an
upcast class value may hold.

The proof deliberately stops there. A trait-typed value, struct, or enum has a different
possible-value model and remains accepted without a false-result warning until that model is
designed. `conformance/diagnostics/impossible-type-test.em` covers both the warning and a
subclass that makes the trait test possible.

## LSP slice two, part one: inferred-type hover, 2026-09-20

A roadmap review had marked LSP slice two (hover, go to definition, find references, rename,
completion) as "mostly more of the same kind of work, not new design risk" — an
underestimate corrected by actually reading `Lsp.zig`'s own header, which named exactly what
was missing: an offset-to-AST-node lookup, a general per-expression type map, and, for
completion only, a different parser recovery strategy. Hover needed the first two; this
session built them and shipped hover, deliberately as its own slice rather than attempting
all five features at once.

The type map turned out simpler than expected. `Checker.zig`'s `typeOf` was already the one
function every expression's type passes through; wrapping it (`typeOf` now calls the renamed
`typeOfUnrecorded` and records the result) reaches every call site without touching any of
them, so the recording cannot fall out of sync with what checking actually computes. The
first attempt tried to restructure `typeOf`'s existing `return switch (...) {...}` in place,
which broke type inference on several bare enum-literal arms (`.invalid`) that relied on the
`return` statement's top-down context; the wrap-instead-of-restructure approach sidesteps
this entirely by leaving the original switch untouched.

The map's value had to carry a file index, not just a `Type`: a byte offset is only
meaningful within its own file's `Source`, and a flat, project-wide map without that tag
would let one file's expression span numerically collide with another's.

The bigger discovery was that the LSP had no project awareness at all — every open file was
checked alone, `emerald.check`'s lone-file path, regardless of whether it actually belonged
to a multi-file project on disk. Hover is close to useless without this (a file's own
sibling declarations would look undefined), so this session fixed it for hover and
diagnostics both, rather than shipping hover on top of a known-broken foundation. The fix
reuses `Project.load` (the CLI's own loader), with the editor's in-memory buffer substituted
for the one file actually open, so unsaved edits are what gets checked rather than stale
disk content. Diagnostics are still only published for the currently open document, filtered
by which project file each diagnostic belongs to (`Diagnostic.file`); publishing a whole
project's diagnostics for files the editor has not opened is a possible future refinement,
not attempted here.

Getting checking's detail out of the pipeline needed a new `emerald.analyzeProject`, since
the existing `check`/`checkProject` discard `Checker.Checked` before returning. The first
version of this leaked a real bug: it freed the synthetic prelude `Source` as soon as its own
function returned, on the reasoning that `analyze()` already does exactly that and works
correctly. The reasoning was incomplete — `analyze()`'s diagnostics are formatted into
strings *during* checking, while `checked.expression_types` keeps raw `Type` values formatted
only later, by hover, after the prelude source was already gone. Every declared name
(`Ast.StructDeclaration.name` included) is a zero-copy slice of its own file's source, so
hovering over anything whose type is a prelude-declared class (`RuntimeError`, not just a
trait like `Ordered`) read freed memory — caught by a real test showing `[170, 170, ...]`
(Zig's debug-mode poison byte) instead of the name. The fix keeps the prelude `Source` inside
`Analysis` itself, freed only by its own `deinit`. Both the bug and the fix are pinned by a
regression test that formats a prelude type's name after `analyzeProject` has returned.

The apparent hang chasing that bug down turned out to be two unrelated tooling issues, not
Emerald bugs: a hand-rolled test script's `read_message` called one extra time per
notification (consuming the diagnostics notification inside a discarded `call()` return, then
blocking forever on a second message that was never coming), and this sandbox's `pkill`
silently aborts the rest of a compound Bash command on its own nonzero exit even under
`|| true`, which had been masking cleanup and producing misleading "no output at all"
results. Neither should be mistaken for a server-side defect if seen again.

## Emerald 0.4.0 release, 2026-09-23

`v0.4.0` was published from `5447b55` after Debug and ReleaseSafe tests, normal build,
documentation-example validation, whitespace checks, and a local baseline-CPU release-archive
smoke. GitHub Actions then built and package-smoked Linux x86_64, macOS ARM64, and Windows x86_64
archives before publishing them with `SHA256SUMS`. Development resumed at `0.5.0-dev`.

## Root README refresh, 2026-09-23

The root README became a concise user entry point instead of a history of implementation work.
It now leads with the shared Emerald SVG, a runnable first program, Mise installation, common
commands, source build instructions, and links to the language guide, library reference,
examples, and diagnostics guide. Internal implementation status, agent coordination, and the
source-tree inventory were removed from this user-facing page.

## Emerald 0.5.0 local release, 2026-09-23

`v0.5.0` was tagged locally at `c0dea26`, following `ae1e5e3`'s inline conditional
expressions and the Random method-name collision fix. Debug and ReleaseSafe suites passed.
A baseline-CPU ReleaseSafe build with `-Dversion=0.5.0` was packaged, unpacked, and checked
through version, help, check, run, test, format, explain, and REPL commands, plus both new
conformance examples. Documentation checks passed for 93 linked files. No push or GitHub
publication was performed; cross-platform packaging remains the release workflow's job.
Development resumed at `0.6.0-dev`. Earlier platform-library roadmap edits were preserved
outside these release commits.
The `0.6.0-dev` bump also passed Debug and ReleaseSafe tests, a normal build and version
check, documentation-example validation, and `git diff --check`.

## Type-declaration audit fixes, 2026-09-24

An audit of type declarations against the spec (all four kinds, both brace styles, one-line
bodies, the removed braceless form, namespaces, module-private types, and enum members) found
two small defects, both fixed here. First, the formatter split every enum value onto its own
line, contradicting the decision table's reason for allowing commas ("so a short enum such as
`small, medium, large` [can] stay on one line") and 18.3's rule that the author's line breaks
decide list layout. A run of enum values written on one line now stays on one line; a run that
spans lines, or holds a comment, stays one value per line. Second, a type declared as the last
statement of a block reported its correct "belongs at the top level" error plus a spurious
"this block is never closed": the declaration had already parsed completely, but it was still
treated as a failed statement, and statement recovery's "a stray `}` is the failed statement"
rule then consumed the enclosing block's own brace. It is now a `note`, the parser's existing
mechanism for exactly this case, so every misplaced declaration in a block is reported and
nothing else is. The message's article also now reads "an enum declaration."

The same audit found that 14.3's nested types were never implemented, and that nothing recorded
their absence; they are the subject of a separate design plan. Braceless type bodies were
confirmed removed by 10.6's deliberate decision, not broken.

## Declaration and namespace name clash, 2026-09-24

The first slice of the nested-types plan. A module-level declaration could share its name
with a directory's namespace — `struct Shapes` at the root beside `shapes/` — and the
declaration silently won, so every member of the namespace became unreachable through that
path; the only symptom was "`Shapes` has no type-level member named `Circle`" at a use. Nested
types would have given the same path two legitimate meanings, so the user approved making it
an error instead of a precedence rule. `Resolver.reportNamespaceClashes` runs once hoisting
is done and compares every namespace (and prefix of one) against the declaration keys. Only
an exact key match can collide, since member keys hold `::` and private keys hold `#`. The
report names the directory as the files spell it, so a nested namespace reads
`graphics/ui/`. No existing example or conformance case relied on the shadowing.

The same probe found that built-in names are inconsistent: `Math` and `Program` deliberately
yield to a project namespace of the same name, but a prelude class such as `File` wins over a
`file/` directory and hides it. That is recorded as a rough edge awaiting a decision rather
than changed here.

## Nested types: parsing, formatting, and registration, 2026-09-24

Slice 1 of the nested-types plan. A `struct`, `class`, `enum`, or `trait` declared inside a
struct, class, or enum body now parses (a trait body refuses one with its own message), and
formats in place, idempotently, in both brace styles. The slice grew past "parse and register
keys" once it was clear what the rest of the pipeline would do with a declaration it did not
know about: the checker would have skipped a nested type's bodies, so a type error inside one
passed `check`, and the formatter, which prints only the members it knows, would have deleted
nested types from the file. So the resolver, checker, and interpreter each recurse through a
type's nested declarations under `Outer::Inner` keys, the type-member key form 10.4 already
uses, which cannot collide with a directory namespace's `Outer.Inner`. The checker's base,
trait, and field helpers used to recompute a type's key from its bare name; they now take the
key, which is the only way a nested type's key can reach them.

Nested enums exposed one more bare-name dependency: each enum value carries a synthesized
annotation and initializer naming its enum, and a nested enum's bare name does not resolve by
design (decision 3). The parser now records the enum as the declaring file's key map names it,
`Console::Color`, which that map resolves to the full key in root and namespaced files alike.

A nested type clashing with any member of its enclosing type is reported at the nested type as
"already a member of `Outer`", naming the shared name space. Paths through a type
(`Console.Color.red`) are slice 2.

## Nested types: reaching them by path, 2026-09-24

Slice 2 of the nested-types plan. `Console.Color.red`, `Ui.Console.Pair.Deep("x")`,
`const c: Console.Color`, `extends Zoo.Animal`, `with Zoo.Named`, and
`using Color = Console.Color` all resolve now. Before this, `qualify` treated a chain as a
namespace path or as a type plus one member, so `Console.Color.red` qualified only its inner
`Console.Color` and left `.red` as a property read on a type, reported as "`Console.Color` is
an enum, not a value" with a suggestion that repeated what the reader had written. The
resolver now descends through nested types after a leading type or the longest namespace
prefix, and hands the last segment to the existing `qualifyTypeMember`. That reuse brought the
not-inherited diagnostic (`Dog.Tag` suggests `Animal.Tag`) with no new code. For annotations,
both `typeKeyOf`s split the written path at the longest prefix that is a type; slice 0's clash
rule is what keeps that from being ambiguous.

Privacy mostly came for free: 10.5's rule is already a textual "inside the braces" check, and a
nested type's braces sit inside its enclosing type's, which is exactly decision 6. Annotations
were the gap, since only expressions went through the member check, so a private nested type
written as a type is now checked segment by segment. A misspelled capitalized member now reads
"`Console` has no nested type named `Colour`" and lists the real ones, sorted so the message is
stable.

A type-level member of a nested type names that type bare where it is declared
(`func Pair.zero()` inside `Pair`), matching how the nested type itself is declared, and is
used through the full path (`Console.Pair.zero()`). The parser already enforced this with a
clear message.

## Nested types in the language server, 2026-09-24

Slice 3 of the nested-types plan. Document symbols now nest types, and hover needed nothing,
since it shows checked types, which already display as `Console.Pair.Deep`. Most of the work
was in paths. The resolver records a qualified path as one reference to its final member, so
before this neither `Console` nor `Color` in `Console.Color.red` navigated anywhere — true of
top-level types too, not only nested ones. The server now reads a segment it has no target for
as the path written up to it, the same way it now reads a written type, so every segment of an
expression, annotation, or `using` path goes to its declaration and counts as a reference.

References had been listing every enum declaration once per value: each value carries a
synthesized annotation naming its enum, spanning the enum's own name. Those are skipped.

Rename had two alias bugs that predate nested types. A use spelled through an alias
(`using Paint = Graphics.Color`, then `const p: Paint`) was rewritten to the new name, which
that file cannot see; and the alias's own path was never renamed, leaving it pointing at a type
that no longer existed. Rename now includes `using` paths, and edits only text spelled with the
declaration's own name that does not begin a path with one of the file's aliases. An alias
spelled exactly like the declaration (`using Color = Ui.Console.Color`) is the case that makes
the second condition necessary. Renaming that nested `Color` to `Hue` across the run case and
running the edited program was the check.

Testing completion showed that it analyzes a rewritten copy of the document, so a statement
typed into a project's non-entry file fails before completion can answer; completion was
verified in the entry file, where statements belong.

## Nested types: documentation and integration, 2026-09-24

Slice 4, which completes the nested-types plan. Rewrite-context 14.3 now states the rules the
user approved, with an example that runs; 14.2's alias rule names nested types; and the
decision table records why nested types are keyed as type-level members, declared bare, and
always reached qualified. The language guide's objects page gained a "Nested types" section
pointing at `conformance/run/nested-types`. The fuzzer's valid-program templates now include a
nested enum, a nested struct with a `Self`-returning method and a nested type-level function,
and an exhaustive `case` over the nested enum; the template was run directly on both branches,
since a template that failed to check would pass the fuzzer silently.

The Console styling plan had been waiting on this to spell its color type `Console.Color`.
Before updating it, a nested enum was added to the prelude's `Random` class temporarily, to
confirm that a prelude-declared nested type, keyed under the internal `emerald.` prefix,
resolves in values, annotations, and `case` like any other. It did, and was removed.

## Empty bodies on one line, 2026-09-24

The formatter opened every body onto separate lines, so the spec's own
`class InvalidScore extends Error { }` and `else { }` were not canonical. The user decided that
an empty body stays on its header's line; a body with content still expands, so ordinary code
keeps one canonical shape. The spelling follows the spec, `{ }`, and applies in both brace
styles, since Allman's brace on its own line opens a body's lines and an empty body has none. A
body holding only a comment keeps its lines, so the comment is never displaced, and blank lines
inside an empty body are dropped. It covers type declarations and every statement block and
function body. Checking the examples against the new rule showed three of them had never been
formatted at all (`} else {` on one line); all four affected examples are canonical now.

## The `Emerald` namespace, slice 1: writable and reserved, 2026-09-24

The prelude's internal namespace was lowercase `emerald`, chosen so no program could write it
or collide with it. It is now `Emerald`, written like any other namespace, so a program that
declares its own `File` still reaches the built-in as `Emerald.File`, in expressions,
annotations, and aliases. That needed very little new resolution code: nested types' path
handling already walks a namespace, then a type, then a member. The interpreter matched native
functions by nine hardcoded `"emerald."` prefixes; they now use the shared constant.

Only one name is reserved, and it never grows. A root-level declaration named `Emerald` is an
error. A top-level `emerald/` directory is refused by the project loader rather than the
resolver, because the resolver tells the prelude apart from user files by its namespace
string, and a user `emerald/` directory would otherwise have shared it.

`using Emerald` is allowed but reported as redundant. The resolver had never reported a
warning: `Resolved.ok()` treated any diagnostic as fatal, and when resolution succeeded only
the checker's diagnostics reached the report. Both are fixed, and resolver warnings now join
the checker's report in source order.

Following that path turned up an older bug. A directory whose name cannot be a namespace was
reported only if some file also had a lex or parse error: after parsing, the later stages
returned only their own diagnostics, dropping the directory report. A project with a lone
`2bad/` directory passed `check` and ran. Bad directories are now carried into every later
report and stop execution. The existing conformance cases had both paired a bad directory
with a parse error, which is why they never noticed.

One implementation note for anyone touching `analyze`: a report literal that copies
`arena_state` must not allocate from that arena in the same literal, since the copy is taken
first and misses the later allocations. The first version of the merge did exactly that and
leaked.

## The `Emerald` namespace, slice 2: every built-in, and a project name always wins, 2026-09-24

The built-in functions joined the namespace: `Emerald.print` reaches the built-in even inside
a program's own `func print`. Both stages recognized a built-in by the written name of a plain
call, so the qualified form is keyed `Emerald.print` (apart from a root-level `print` of the
program's, whose key is `print`) and each stage maps that key back to the built-in's name. In
the interpreter that meant pulling the bare-name dispatch into `callBuiltin`. Used as a value,
`Emerald.print` gets the same "can only be called" error as the bare name; the first version
silently accepted it, since the qualified key had no binding.

The rule is now the same everywhere: a project name wins over a built-in. Declarations already
did; `Math` and `Program` already yielded to a project directory; a directory named like a
prelude class, such as `file/`, was the one case where the built-in silently won. The resolver
now skips a prelude type when a project namespace has its name. Each of those is also a
warning whose help names the qualified form, for module-level declarations and top-level
directories only, since a parameter named `input` or a local named `write` is an ordinary name
rather than a mistake. One existing fixture, about a program that declares its own `Ordered`,
gained the warning, and its error now suggests `with Emerald.Ordered`, which was confirmed to
adopt the built-in trait.

## The `Emerald` namespace, slice 3: documentation, 2026-09-24

The plan is complete. Rewrite-context 14.2 now states the built-in rules with an example: a
project name always wins, with a warning naming the qualified form; locals are exempt; `Emerald`
is the one reserved name; `using Emerald` is redundant; diagnostics keep bare names. 15.1 no
longer says the prelude functions are stored "in an internal namespace", since that namespace
is now written like any other. The language guide's projects page and the library inventory
explain `Emerald.` to readers, and both new snippets were run.

## Console styling, slice 1: helpers under a forced policy, 2026-09-24

`Console` is now an ordinary prelude class with the nested `Console.Color` enum, eight basic
foreground helpers, four text-style helpers, and `Console.style`. Styled values are ordinary
`String`s containing ANSI SGR sequences. The one native primitive, `Console._color()`, reads
the execution-owned `Streams.color` bool; every other Console function has an Emerald body, so
named/defaulted `style` arguments and interpolation keep their usual behavior. A new
`conformance/color/` kind forces that policy on, while ordinary runs stay unstyled by default.

Layers use their specific close codes and reopen after either their own close or a full reset.
That makes nested foreground/background styling and the shared bold/dim close code compose
without leaking or losing the surrounding style. The focused conformance program asserts every
escape sequence in source, rather than placing raw terminal bytes in a golden file.

The prototype's bare `Console` references were not safe once project declarations could shadow
built-ins: a project's own `Console` could be resolved while checking prelude method bodies.
The shipped prelude therefore writes `Emerald.Console` internally. A malformed project
declaration of the reserved `Emerald` name exposed the same recovery-path hazard, so the
resolver keeps prelude self-qualification anchored to its namespace while it reports that
program error. Type-member completion now also filters private names; otherwise Console's
native and implementation helpers would have appeared in `Console.` suggestions.

## Console styling, slice 2: plain text, 2026-09-24

`Console.plain(text)` is a single native scanner that removes complete ANSI SGR sequences from
an ordinary Emerald `String`. A sequence is precisely `ESC`, `[`, zero or more ASCII decimal
digits or semicolons, then `m`; this includes `ESC[m` and combined codes such as
`ESC[1;31m`. It deliberately leaves cursor controls, bare escape characters, incomplete
sequences, and malformed sequences alone. It is a styling-removal tool, not a terminal-security
sanitizer, and its result does not depend on the execution's color policy.

The forced-color conformance case now strips nested Console styling and direct SGR strings,
then proves the scanner retains the non-SGR cases. The ordinary color-off run case confirms the
same removal behavior without styled helper output.

## Console styling, slice 3: real terminals, 2026-09-24

`emerald run` and `emerald test` now accept `--color=auto`, `--color=always`, and
`--color=never`. The decision is a small pure `ColorPolicy` function: an explicit always/never
flag wins; otherwise non-empty `NO_COLOR` wins over `FORCE_COLOR`; a non-empty FORCE_COLOR other
than `0` wins over `TERM=dumb`; and the remaining automatic case requires stdout to be a
TTY that supports ANSI. The REPL uses the same automatic path, while no Emerald program can
change the policy during an execution.

On Windows, automatic color treats an ordinary stdout console as eligible, then asks Zig to
enable virtual-terminal processing; a failed setup simply leaves auto color off. Forced output
never changes a console, so it remains suitable for redirected files, pipes, and CI logs. The
CLI test suite covers flags, environment wiring, and `--` arguments; a Linux pseudo-terminal
probe and a pipe probe checked the real automatic behavior. Windows setup is left to CI rather
than claimed as locally verified.

## Console styling, slice 4: documentation and integration, 2026-09-24

Console styling closes out with `docs/library/console.md` (signatures, the nesting rule, and
the color policy's precedence), an `inventory.md` row, and `examples/console.em`, checked both
plain and with `--color=always` and by `emerald format --check`. Rewrite-context 15.6 records
the settled design under Standard library organization, and 22 gains five decision-table rows:
the styled-value representation (an ordinary `String`, not a dedicated type), the policy's
ownership by the runtime rather than a mutable Emerald-level switch, the CLI-flag-plus-
environment-variable precedence and why `NO_COLOR` beats `FORCE_COLOR`, and nesting's
reopen-the-enclosing-style rule alongside `plain`'s deliberately narrow scope. The roadmap
entry in 24 now points at 15.6 instead of describing Console as unimplemented.

Console is Emerald's first complete official platform library. Its line-oriented interaction
(prompts, multi-select, tables) remains a later, separately designed slice of the same
library, and `Tui`, `Graphics`, `Gui`, `Audio`, and `Game` remain undesigned roadmap items.

## Roadmap passes and handoff reconciliation, 2026-09-24 to 2026-09-25

Three documentation-only commits followed Console slice 4 (`e0e5363`). `f6099cc` made
`Table`/`Panel` layout widgets and prompts later slices of Console itself and dropped a
separate `Tui`. `79c0861` parked `Graphics`, `Gui`, `Audio`, and `Game` rather than keeping
them on the roadmap: each needs native bindings and likely its own release cadence once a
package manager exists. `076ee72` added rewrite-context 15.7, the standard-library backlog,
which puts date/time first.

The 0.5.0 entry above records a local tag that was not yet pushed. `v0.5.0` at `c0dea26` was
later pushed and published as a GitHub release (2026-09-24). The handoff still called Console
slice 4 uncommitted and 0.5.0 unpublished. On 2026-09-25 it was brought back in line with
Git, and its per-slice validation history, all already recorded above, was cut down to the
current state.

## Dates and times, slice 1: `Date` and `Duration`, 2026-09-25

The user accepted every recommendation in `docs/date-time-design-plan.md` and left the open
question about sleeping to the executor, who included `Program.sleep` in slice 3. Slice 1
writes `DateTimeError`, `Weekday`, `Duration`, and `Date` in ordinary Emerald in the
prelude. Calendar conversion uses Howard Hinnant's days-from-civil algorithms in floor
arithmetic. `Duration` keeps whole seconds and a nanosecond part so that it can span the
full year range. Its division by a large `Int` uses overflow-free binary long division
rather than widening.

Two engine changes came with it. First, a runtime failure inside the prelude's Emerald code
used to crash the CLI's renderer, because the prelude is not among the files it renders.
`raiseTyped` now moves such a failure out to the program's first call into the prelude and
drops the prelude frames. Console had never raised, so nothing had exposed this.

Second, `moduleView` copied the whole prelude and module scope, every type and member
included, into a fresh map for each function body. Every branch's definite-assignment
snapshot then walked that copy. Cost grew with bodies × names, so about 400 prelude lines
nearly tripled startup. The view now copies only variables, and functions and types are
found in place through `moduleFallback`, in the stack's own module-then-prelude order.
Startup for `print(1)` went from 13.6 ms to 5.5 ms (ReleaseSafe). Without the date code it
is 3.3 ms, down from 5.0 ms.

The named-unit rule (decision 2(a)) is a `named_units` flag on the checker's `Parameters`,
set for three prelude keys. It reports a positional argument and lists the units the call
accepts.

## Dates and times, slice 2: `Time` and `DateTime`, 2026-09-25

`Time` and `DateTime` join `Date` in the prelude. The parsing and validation that all three
share moved out of `Date`'s private type-level functions into private module-level
functions (`_digits`, `_date_shaped?`, `_time_shaped?`, `_date_problem`, `_time_problem`,
`_shifted`, and so on). A type's private members cannot be reached from another type, and
private module-level names cannot be reached, or captured, by a program. A probe confirmed
both before the move.

A module-level list of month names broke an unrelated conformance case. The checker's
module-setup ordering analysis treated the prelude's `_month_names` as one of the program's
module bindings. It reported that a program's setup call read `prelude.em#_month_names`
before assignment. The list became a function, and the gap is recorded as a rough edge.

`DateTime.add` follows Temporal's order: the time units are balanced first, then years and
months move the date, then weeks, days, and the carried days. `duration_until` is the plain
wall-clock difference. `moduleView` now caches the keys of the variables it copies, and
rebuilds that list only when the prelude or module scope gains a name. Slice 2's extra
prelude bodies had made each view's full iteration show up in profiles again.

## Dates and times, slice 3: `Instant`, clocks, fixed zones, `Stopwatch`, and `Program.sleep`, 2026-09-25

`Instant` is two private `Int`s, whole Unix seconds and a nanosecond part. Everything builds
one through `Instant._at`, which normalizes it and checks the years 1 through 9999. Its
operators are named `after`, `before`, and `since`: 11.5 reserves `add` and `subtract` for
`Self -> Self`. `Instant` cannot reach `Duration`'s private fields, so it needed exact
integer access. `Duration` gained `whole_days` through `whole_nanoseconds` (toward zero),
which beginners also want ("90 minutes").

The native surface is three calls. `Instant._now` and `Stopwatch._ticks` read
`std.Io.Clock.real` and `.awake`, dispatched by key next to `Console._color`.
`Program.sleep` is a special resolver key like `Program.arguments` and `Math`'s functions,
because `Program` is not a prelude class. The checker accepts exactly one `Duration`, and
the interpreter reads the `Duration`'s fields and calls `std.Io.sleep` on the monotonic
clock.

`TimeZone` has one constructor that takes a name: `"UTC"` or an offset such as `"+05:30"`
for now. `TimeZone.fixed` formats the offset and calls it, so slice 5's IANA names extend
the same constructor. A private-field built-in used to get 10.5's "give it a default or a
constructor" help. It now names the type-level function that gives one.

Editing the prelude exposed a tooling gap: a checker diagnostic inside the prelude trips an
assertion instead of printing. A temporary print in `emerald.analyze` showed two redundant
`.or(0)` calls, which narrowing had already made unnecessary. The print was removed before
committing.

## Dates and times, slice 4: the local zone, 2026-09-25

`src/TimeZone.zig` is the rule engine. It reads a zone as TZif transitions followed by a
POSIX TZ rule for every later moment. `std.tz` parses the file but does no lookup and
leaves the footer rule as text, so evaluating `Mm.w.d`, `Jn`, and `n` dates is
Emerald's own code. It has unit tests for United States and Sydney daylight time, rule
forms, a TZif file built byte by byte (the PyPI Zig ships none of `std.tz`'s fixtures), the
choice of source, and Windows's zone description.

`localSource` is the pure half of glibc's order (`TZ`, then `/etc/localtime`), and
`main.zig` does the reading. Windows gets `GetDynamicTimeZoneInformation` through a
hand-declared kernel32 binding, since `std.os.windows` has none. The Windows build compiles
here, but only CI runs it. The resolved `TimeZone.Local` travels in `emerald.Streams` next
to `color` and defaults to UTC. `conformance/local-zone/` runs with a fixed `EST5EDT` so
clock changes are testable everywhere, and its expectation matches what the CLI prints with
the real `EST5EDT` zone file.

On the Emerald side, a rule-based `TimeZone` has no fixed offset and asks the runtime for
one. `DateTime.to_instant` resolves repeated and skipped wall-clock times from the offsets a
day on either side: try the earlier offset, then the later, else move forward by the gap.
That reproduces Temporal's `"compatible"` choice without the runtime exposing transitions.
The first draft of the local-zone test could flake at midnight, because it read today
before now and allowed yesterday. It now reads now first and allows tomorrow.

## Dates and times, slice 5: named zones from a built-in database, 2026-09-25

Slice 4's CI run failed on Windows ReleaseSafe. After `Program.sleep(20 ms)`, a `Stopwatch`
had measured less than 20 ms, because a Windows timer can wake early relative to the
monotonic clock. Rather than loosen the test, `Program.sleep` now sleeps against a
deadline on that clock (`57b58a5`), and CI went green everywhere. That run was also the
first to execute the Windows zone binding.

The database is IANA's own TZif files, taken from PyPI's `tzdata` wheel. IANA's site and
ziglang.org were unreachable from the cloud sandbox, but PyPI and GitHub were not. Each
distinct file is stored once behind a sorted name index and zlib-compressed: 598 names,
345 files, 56 KB. `tools/update-tzdata.py` also turns CLDR's `windowsZones.xml` into a
small generated `tzdata.zig`, so the Windows local zone can be named without decompressing
anything. The interpreter decompresses the database into its run arena the first time a
program names a zone, and caches each parsed zone. Named lookups prefer it over the
machine's rules so that a name means the same everywhere.

Testing named zones exposed a slice 4 regression. Making `TimeZone`'s private offset an
`Int?` had silently stopped zones being dictionary keys, because an optional is not a key
type. It is now an `Int` beside a `Bool`, and `run/named-zones` uses a zone as a key.

## Dates and times, slice 6: documentation and integration, 2026-09-25

The milestone closes with eight library pages. An overview page, `dates-and-times.md`, says
which type to choose, then one page each covers `Date` (with `Weekday`), `Time`, `DateTime`,
`Instant`, `Duration`, `TimeZone`, and `Stopwatch`. They add inventory rows, a
`DateTimeError` paragraph on the errors page, and `examples/dates.em` with the plan's
beginner programs. Every inline snippet was run; the `Stopwatch` one had called an undefined
`build_report()` and now does real work. The fuzz generator gained a valid-program template
that moves dates and converts a random New York hour on the spring-forward day.

Given the choice, the executor decided to ship third-party notices. Unicode's License V3 asks
for its notice to travel with copies of CLDR data, which every binary now embeds. Release
archives had carried only the binary, without even Emerald's own MIT `LICENSE`.
`THIRD_PARTY_NOTICES.md` quotes Unicode's terms (fetched from CLDR's repository) and Zig's
MIT license (from the pinned toolchain) verbatim, and notes that IANA's data is public
domain. The release workflow packs it and `LICENSE` beside the binary, and its smoke test
checks both unpacked.

Over the milestone, startup for a ReleaseSafe `print(1)` went from about 5.0 ms to about
8.3 ms, roughly 1 ms per slice of prelude code. The zone database adds nothing, since it
loads only when a program names a zone. Profiling found and fixed two checker hot spots on
the way: the module view copy, and its per-body iteration. What remains is checking every
prelude body on every run; the handoff lists it as the next performance candidate.

## Regular expressions, slice 1: Unicode data, 2026-09-25

The user chose regular expressions after dates and times, and accepted
`docs/regex-design-plan.md`. The plan's decisions were the executor's, the user having left
judgement to them: Emerald's own linear-time engine, matching by grapheme, ASCII `\d`,
literal replacements, and literal patterns checked before a program runs.

Slice 1 adds the Unicode data `\w` and `ignore_case` need. `unicode.org` is blocked from
cloud sessions, but Unicode's own `unicodetools` repository on GitHub serves the UCD files.
Regenerating the existing tables from that mirror reproduced `src/unicode/tables.zig`
byte for byte before anything changed, which established that it is the same data.
`tools/unicode/fetch.sh` now takes a `UCD_BASE` override and fetches `CaseFolding.txt`.
The generator gained two tables. `word` is UTS #18's `\w`, precomputed as one merged range
table: Alphabetic, Join_Control, and the Mn, Mc, Me, Nd, and Pc general categories, with
UnicodeData.txt's First/Last range lines expanded. `simple_fold` holds CaseFolding.txt's C
and S mappings. A separate Python parse agreed on every code point. Nothing outside the
tests uses them yet, so the binary is unchanged in size until slice 2's engine does.

## Regular expressions, slice 2: the engine, 2026-09-26

`src/Regex.zig` is a parser to a syntax tree with grapheme positions, a compiler to
instructions, and a Pike VM. Every thread advances through the text together, in priority
order, so matching is linear and leftmost-first. Threads live in a sparse set with capture
slots; the closure over non-consuming instructions uses an explicit stack with restore
frames, not recursion. The text is segmented into graphemes once. At each position the
current grapheme is described once, as its NFC bytes, first code point, and line-break and
word flags, rather than once per thread.

Two refinements came from building it. First, a set decides by a character's first code
point in NFC rather than as written, so decomposed `é` no longer slips into `[a-z]`.
Second, adjacent literals that form one grapheme merge (`\r\n`, `e\u{301}`); otherwise a
pattern could never match a text's one-grapheme `\r\n`.

`tools/regex-differential.py` generates random ASCII patterns and texts, asks
`tools/regex_probe.zig` (run with `zig run` and the engine as a module), and compares with
Python's `re`. Its first 3,000 cases found five differences, all in two categories where
Python differs from linear-time engines. Python takes one empty round of a repetition and
records its capture, which RE2 documents as a deliberate difference from Perl. Python's
`\B` also never matches an empty text. Both are now documented behavior, and the generator
leaves them out; 30,000 further cases agreed exactly. The first version of the linear-time
unit test was wrong, not the engine: `(a*)*b$` does match a run of `a`s ending in `b`.

## Regular expressions, slice 3: the Emerald API, 2026-09-26

`Regex`, `Regex.Match`, and `RegexError` are in the prelude. The constructor takes its
options by name and asks the native `_problem` whether the pattern compiles, raising
`RegexError` when it does not. Every other method passes the pattern and options,
positionally, to a native in `Interpreter.callRegex`. `Regex.Match` keeps each group's span,
text, and name in private fields, ready for slice 4. Privacy (10.5) means `Regex`'s own code
cannot set a nested type's private fields, so the native `_find` builds the match values
directly; programs cannot build one at all.

Two behaviors the plan had left open were settled here, following Go and Rust. First, an
empty match just where the previous match ended does not count. Second, an empty match at
the very start or end of a text splits nothing off, which is what makes an empty pattern
split between every grapheme.

The first version was slow on a 1.2 MB text: about a second for `find_all('\w+')`,
`replace_all`, and `split` each. Three changes brought that down. `Regex.Matcher` keeps
the engine's threads and scratch space between the runs of one search, instead of
allocating them per match. ASCII characters skip normalization. And `replace`,
`replace_all`, and `split` became natives over match spans, where they had built a match
value for each match and run an Emerald lambda to filter them. The results are
`find_all` at 0.7 s (mostly building 240,000 match values), `replace_all` at 0.3 s, and
`split` at 0.5 s, against 0.15 s for the engine alone. Startup rose about 0.3 ms.

## Regular expressions, slice 4: groups, 2026-09-26

`group`, `group_maybe`, `named`, and `named_maybe` are Emerald methods on `Regex.Match`,
reading the private fields the native `_find` fills; slice 3 had laid them out for this.
Each match now also holds its pattern, as a retained reference and not a copy, so that
messages can quote it. A group that took no part raises `RegexError` from `group` and
`named` and gives `nothing` from the `_maybe` forms, as 9.4's `to_int` pair does. A group the
pattern lacks raises from every form, with a message naming the groups the pattern has.

Formatting the new conformance case turned up an unrelated bug: `emerald format` printed
`due?.named("year")` as `due.named("year")`. `Formatter.printMemberAccess` never wrote the
`?` of an optional member access, so formatting a program, or saving it in an editor with
format-on-save, could change what it meant. It is fixed, with a `format/` case.

## Regular expressions, slice 5: checking literal patterns, 2026-09-26

`Checker.checkLiteralPattern` runs once a `Regex(...)` call's arguments have been checked. When
the pattern argument, positional or `pattern:`, is a string literal, it compiles it with
the same `Regex.compile` the runtime uses. The literal's value has had its escapes applied,
so a grapheme position maps back to the source only when the source text between the quotes
is exactly the value. That holds for every single-quoted pattern, which is the style the
guide teaches. In that case the diagnostic underlines the one character and leaves the
position out, since the caret shows it. Otherwise it underlines the literal and names the
position. The LSP needed no change: it publishes the checker's diagnostics, and a JSON-RPC
session confirmed the UTF-16 column after an emoji and that fixing the pattern clears it.

Two slice-3 conformance cases wrote bad literal patterns to exercise `RegexError`; they now
build the pattern as the program runs, which is the case that still reaches run time.

## Regular expressions, slice 6: documentation and integration, 2026-09-26

`docs/library/regex.md` is the reference. Beyond the signatures, it has a table of the pattern
language and a section listing every deliberate difference from other engines, each with its
reason. Every claim on the page was run before it was written down. `examples/regex.em`
holds the plan's beginner programs; it reads tickets from a list rather than `input`, because
the doc check runs examples unattended. `String`'s search section now points to `Regex` for
searching by pattern. Rewrite-context 15.4 is rewritten from the design outline into the
settled behavior. Section 22 gains five decision rows (literal replacements, named options,
`\d` and sets, empty matches, and checking literal patterns), and 15.7 marks regular
expressions done. The fuzz runner has a regex template that builds, searches, replaces,
splits, and reads groups.

The milestone is complete. The engine is about 1,200 lines of Zig with no dependency, runs in time
linear in the text, and agrees with Python's `re` on 40,000 generated cases outside the
documented differences.

## Removing completed design plans, 2026-09-26

At the user's request, the six design plans under `docs/` were removed once their work had
landed: console styling, dates and times, the `Emerald` namespace, nested types, operator
annotations, and regular expressions. Each had served as a slice-by-slice handoff while its
milestone was in progress. Their settled behavior is in rewrite-context (sections 11.5, 14.2,
14.3, 15.4, 15.6, and 15.8, with decision rows in 22), and their history is here and in Git.

The date-and-time plan's list of what was left out had no home in the spec, so it moved to the
end of 15.8, matching 15.4's. Code comments that cited a console plan decision by number
now cite rewrite-context 15.6, which states the same precedence. Earlier entries in this
journal still name the plans; those names are history, and `git log -- docs/<name>` finds
the files.

## JSON, slice 1: the parser and writer, 2026-09-26

`src/Json.zig` is a strict RFC 8259 parser and writer, native Zig, with no Emerald-facing type
yet. It parses in one pass and is genuinely iterative: an explicit stack of open containers
(`Parser.stack`) stands in for recursion, the same way `Regex`'s own matcher uses an explicit
stack instead of recursion, so nesting depth is bounded by that stack, not by how deep Zig's
own call stack happens to go. A document nested 200,000 levels deep is refused cleanly rather
than crashing, well past the 512-level limit that ordinary documents are held to. Every common
mistake gets its own message: a trailing comma, single quotes, an unquoted key, a comment,
`NaN`, `Infinity`, and a string that never closes or names half a surrogate pair. Positions are
one-based lines and Unicode scalar-value columns, the same counting `Source.Location` uses.

A number keeps two readings and one writing flag, not one boolean doing both jobs: `is_integer`
(with `int_value`) decides whether a future `int()` accessor should succeed, following the
plan's rule that `3`, `3.0`, and `3e2` all count as whole numbers; `is_float_literal` decides
only how the writer formats the number, so a parsed `3.0` writes back as `3.0`, not `3` — the
plan's "nothing surprising" principle, applied to the parser and writer themselves before any
Emerald-facing type exists to apply it to. The first draft conflated the two, which silently
turned every whole `Float` into an `Int`-looking number on the way back out; the round-trip
unit test caught it.

JSONTestSuite (`tools/json/fetch.sh`, cloned with `git` since this session's GitHub access is
scoped to specific repositories over the REST API and codeload.github.com, but not over the
plain git protocol or raw.githubusercontent.com) checks 318 files
(`zig build json-conformance`). Two disagree, both the plan's own documented exception: it
refuses a duplicate key, where JSONTestSuite counts either answer acceptable, since most
parsers take the last value. `tools/json/differential.py` generates random documents, and
documents with one common mistake introduced, and checks agreement with Python's `json`;
0 differences over 25,000 cases (seeds 1–5), once its generator gave every key a running
number so it never produces a duplicate on its own. A 1 MB generated document parses in about
38 ms and writes back in about 6 ms (ReleaseSafe).

## JSON, slice 1 review fixes, 2026-09-26

Reviewing slice 1 found four defects in `src/Json.zig`, each now fixed with a unit test:

- **A whole number at 2^63 crashed.** `Int`'s upper bound, 2^63 - 1, is not representable as
  an `f64` and rounds to 2^63, so an inclusive `<=` check let `9223372036854775808` (or
  `9223372036854775807.0`) reach `@intFromFloat` and panic. The bound is now an exclusive
  2^63. `Value.initFloat`, the future `Json.from_float`, shared the bug.
- **Duplicate-key checking was quadratic.** Each key was compared with every earlier key in
  its object, so a flat 40,000-key object took 1.1 s to parse; a per-object hash set brings it
  to 25 ms (ReleaseSafe).
- **A string ending in a backslash** said "a pattern cannot end with a single backslash",
  copied from `Regex`; it now gets the unterminated-string message.
- **A message too long for `Problem`'s 400-byte buffer** (a duplicate key hundreds of
  characters long) was cut wherever the buffer ended, possibly inside a UTF-8 sequence. It is
  now cut at a character boundary and ends with an ellipsis.

## JSON, slice 2: the `Json` value, 2026-09-26

`Json.parse`, `Json.parse_maybe`, `JsonError`, and the `Json` value are in the prelude:
`kind`, `null?()`, `count`, `keys()`, `get`/`at` and their `_maybe` forms, and the six
conversions with theirs. Display is compact JSON text, and `Equatable` makes equality JSON's
own: `1 == 1.0`, objects equal in any key order, the path ignored. The value is an ordinary
struct over private fields, built natively by `Interpreter.JsonBuilder`; its path is a
private `var` field the navigation methods set on the copy they return, so a parsed tree
stores no paths at all and navigation needs no native call.

Refusing a document is where the parser and Emerald met. A `Dict` compares keys after
normalization (9.2), so the parser's duplicate check now normalizes too; otherwise a
document with a precomposed and a decomposed "café" would have silently lost one value when
it became a `Dict`. A number too large for a `Float` is now refused rather than read as
Infinity, which `Json.write` cannot write back. JSONTestSuite's invalid-UTF-8 files then
crashed the normalizer, which assumes valid text, so `Json.parse` validates UTF-8 first;
no Emerald program can reach that, since its strings are always valid, but `src/Json.zig`
is meant to stand alone for a future backend.

Writing the prelude code hit the handoff's rough edge — a checker diagnostic inside the
prelude tripped an assertion instead of printing — four times in a row. `emerald.analyze`
now panics with `the prelude has a problem at prelude.em:LINE:COLUMN: MESSAGE` after each
stage instead, which is still a crash (a prelude problem is always Emerald's own bug) but
says what and where. The rough edge is closed.

Two messages from slice 1 were reworded once seen in context: an unterminated string is
reported where the text ends rather than where it began (the message already names that),
and an unescaped control character suggests JSON's own escape (`\t`, or `\u0001`) rather
than Emerald's `\u{0009}`.

A 1.28 MB document of 9,000 records parses in about 150 ms (ReleaseSafe). Startup for
`print(1)` rose from about 7.5 ms to 9.3 ms (median of 60, same machine), the largest single
jump yet; the startup task queued after the standard library now matters more.

## JSON, slice 3: building and writing Json values, 2026-09-26

`Json.null`, the six `from_` builders, and `Json.encode` now complete the manual Json-value
workflow. The builders remain ordinary prelude code: a single private helper fills the same
fields the native parser does, and `Json.encode` delegates to the existing native writer.
That preserves Float-shaped numbers such as `3.0` and `-0.0`, dictionary insertion order, and
the writer's established compact and two-space-pretty forms without duplicating serialization
logic. `from_float` refuses `NaN` and both infinities as `JsonError`; the native writer now
also makes its formerly unreachable non-finite case a catchable `JsonError` as a defensive
boundary check. New end-to-end coverage builds a nested value, tests compact and pretty output
and round trips, verifies fresh paths in built containers, and exercises all three non-finite
spellings.

## JSON, slice 4: encoding program values, 2026-09-26

`Json.encode` now accepts the small recursive set established in the JSON plan: scalar text
and numbers, Bool, optionals, lists, string-keyed dictionaries, enums, date/time values,
`Json`, and structs made from those values. The checker records the source type at each call;
the native encoder uses it to retain element types that a runtime `List` or `Dict` does not
carry. Struct fields and dictionary keys keep their declared and insertion order respectively.

The checker refuses unrepresentable types before execution. Most importantly, a struct with a
bad nested field identifies that field rather than hiding the cause behind the outer struct.
Non-finite Float values are intentionally the one runtime check: their static type is valid,
but their particular value has no JSON representation, so they raise `JsonError`.

## JSON, slice 5: typed decoding, 2026-09-26

`Json.decode(text, as: Type)` now turns JSON directly into the program's known shape. The
`as:` value is deliberately type source syntax, not a runtime type object: the checker returns
that type from the call and records it for the interpreter, which needs collection element types
that ordinary runtime containers erase. The decoder accepts the same recursive type family as
encoding, including enums, plain structs, and ISO date/time types. Structs use their generated
constructors, so their ordinary field defaults still run; missing optional fields are `nothing`
and extra object fields are ignored.

Invalid target types fail at check time. Bad JSON text, missing required fields, and wrong kinds
raise `JsonError` at the source call with a JSON path; paths now also quote keys that do not read
as Emerald names, such as `["first name"]`. The slice's conformance covers nested collections,
enum values, defaults, optional fields, ISO values, target rejection, and representative runtime
failures.

## JSON, slice 6: documentation and integration, 2026-09-26

JSON's public page now distinguishes the two deliberately different workflows: `Json.parse`
and navigation for a document whose shape arrives at runtime, and `Json.encode`/`Json.decode`
for a program's own known types. `examples/json.em` demonstrates both without requiring files
or arguments, so the documentation check can run it safely. The inventory links the page and
example, and the rewrite context now contains the settled rather than in-progress 15.9 rules.

The bounded execution fuzzer also gained a typed struct list that it encodes, parses, and
decodes. That is not a replacement for the focused conformance cases; it puts the new parser,
checker special case, and interpreter conversion into the existing randomized frontend and
execution cleanup path.

## JSON slices 3–6 review, 2026-09-27

Reviewing the builders, typed encoding and decoding, and integration found six defects, each
now fixed with conformance (`run/json-decode-fields`, `run/as-argument`,
`diagnostics/json-encode-decode-as-values`):

- **`as:` was a type in every call.** The parser read any `as:` argument as a type, so
  `describe(3, as: "feet")` failed to parse. It is now a type only in a call written
  `Json.decode` or `Emerald.Json.decode`; the parser cannot resolve names, and the checker's
  help says so when a type is missing.
- **A struct holding itself hung the checker.** `jsonEncodeIssue` and `jsonDecodeIssue`
  recursed through `children: List[Node]` forever. A stack of structs being checked stops
  the second visit; trees now round-trip.
- **Defaults overwrote the document.** Decoding ran every field default after reading the
  fields, so `"volume": 9` came back as the default 5. Defaults now run only for fields the
  document leaves out, the same mask the generated constructor uses, and a default wins over
  `nothing` for a missing optional field.
- **Private fields leaked both ways.** `encode` wrote `_balance`, and `decode` read it (only
  the defaults bug hid that). A private field is now never written and never read; the
  decision row in 22 gives the reasoning.
- **Naming the arguments in the other order crashed.** `Json.decode(as: Int, text: "3")`
  evaluated the type. The text argument is now found by kind.
- **`Json.decode` could be kept as a value**, exposing its placeholder signature. Both
  `encode` and `decode` now report that they have to be called.

Typed decoding's wrong-kind messages now describe the value they found (`found the text
"loud"`), as `Json`'s own conversions do, and a missing field says "this value is missing".

With JSON complete and its behavior in rewrite-context 15.9, `docs/json-design-plan.md` is
removed, as the finished date and regex plans were; `git log -- docs/json-design-plan.md`
finds it. References in `src/Json.zig` and `tools/json/` now cite 15.9.

## HTTP client, slice 2: Emerald API and offline conformance, 2026-09-27

`Http.get`, `delete`, `post`, `put`, and `patch` now provide the accepted synchronous request
surface. A completed `Http.Response` exposes status, reason, final address, normalized headers,
raw `Bytes`, UTF-8 text, and JSON; error statuses raise `HttpError` by default and retain their
numeric status. The interpreter creates one timeout-bounded transport client per program run.

`conformance/http/` starts the cross-platform loopback server from `Http.zig` for each case and
passes its address only through `Program.arguments[0]`. It covers request forms, named
arguments, query percent encoding, headers, redirects, strict mode, UTF-8 and JSON failures,
timeouts, redirect loops, and invalid addresses without reaching the internet. The lower-level
Zig request API was needed because `fetch` drops the response metadata the Emerald API exposes;
the finished body is transferred directly into existing immutable `Bytes` storage.

## HTTP client, slice 3: opt-in live HTTPS verification, 2026-09-28

`zig build http-live` is now the sole manually invoked network check. It is not a dependency of
`zig build test` or CI. It reads the host's proxy settings through Zig's standard
`initDefaultProxies` API, while keeping the process environment private to the runtime; `run`,
`test`, and the REPL all supply that configuration consistently.

The manual run on 2026-09-28 found no configured proxy. It received HTTP 200 from
`https://example.com`, rejected expired, self-signed, and wrong-host certificates at badssl.com,
and classified the reserved nonexistent `.invalid` host as unknown. The resolver returned
`NoAddressReturned` for that host, so it now shares the `unknown_host` mapping with
`UnknownHostName`. The check also evaluates small Emerald programs to verify that the resulting
`HttpError` messages are clear.

Zig 0.16's HTTP client collapses the distinct certificate-validation failures into
`TlsInitializationFailed`. Emerald consequently reports the accurate common fact — the server's
certificate is not trusted — instead of claiming whether it is expired, self-signed, or for a
different address.

## HTTP client, slice 4: documentation and integration, 2026-09-28

The completed client is now settled in rewrite-context 15.10 and the library inventory. Its
reference page documents every request, response, error, redirect, body, header, timeout,
certificate, and proxy rule, with an offline-safe [`examples/http.em`](../examples/http.em): no
argument prints its usage, while an explicitly supplied address makes one request. The finished
design plan is removed, as earlier completed-library plans were.

Documentation records one transport-level correction from the original plan: `response.bytes`
has no UTF-8 conversion, but it follows normal HTTP content decoding, so a gzip response yields
its decompressed binary bytes rather than literal compressed wire bytes. The 64 MB limit applies
after decoding.

The pinned-toolchain check, Debug and ReleaseSafe `zig build test`, `zig build`, documentation
example check, Zig formatting check, diff whitespace check, and Windows/macOS cross-builds all
passed. The cross-builds were followed by a native build before the final documentation example
run, so `zig-out/bin/emerald` remains usable on the development host.
## Negative number literals, 2026-09-26

Writing the website's `Int` and `Float` pages meant telling readers to write `(-3).abs()`,
because `-3.abs()` read as `-(3.abs())` and gave `-3`, and `-3.positive?()` reported "`-`
needs a number, but this is Bool — use `not`". The user called that a bug and chose Ruby's
rule (5.3): a `-` written against a number is part of it, except before `**`, so `-2 ** 2`
stays `-(2 ** 2)`. `Parser.negativeLiteral` folds the sign into the literal and continues
the postfix chain from it; `x -3` is untouched because a `-` after a value is parsed as
subtraction before `parseUnary` sees it. The formatter now prints `-3.abs()` bare, keeps
`(-2) ** 2`, and prints a spaced `- 3.abs()` as `-(3.abs())`, since writing it back as
`-3.abs()` would change its meaning.

Updating the formatter's own test for the minimum Int showed that `Formatter`, `Project`,
and `Range` were never in `emerald.zig`'s test list, so their 24 unit tests had not run in
`zig build test`. One had gone stale: it expected a blank line inserted between top-level
declarations, which 19's formatter rules never do. All three modules are in the list now.

## Startup performance, slice 1: measuring, 2026-09-28

`docs/startup-design-plan.md` records where a ReleaseSafe `print(1)` spends its 9.8 ms:
checking prelude function bodies is half, spread across the library, and about 2,500 page
faults per run make memory a large share. `tools/startup-benchmark.py` measures five programs
(`print(1)`, a language-only program, and one each reaching dates, regular expressions, and
JSON).

The first baseline run showed why the tool compares rather than measures: the same binary
that took 9.8 ms an hour earlier took 22 ms, with the machine idle, and so did an older
build. Something on the host slows the whole WSL2 machine at times. Given two binaries, the
tool alternates their runs, so drift affects both alike, and reports the second as a share of
the first; two builds of nearly the same code came out within about 5% of each other during
the slow period. Every later slice records such a comparison against the build before it.

## Startup performance, slice 2: checking only reachable prelude bodies, 2026-09-28

Every run checked every prelude body, half of a `print(1)`. Now a run checks only the bodies
its program can reach. The rule is deliberately coarse: reaching anything inside a top-level
prelude type (`Emerald.Regex::Match::group` reaches `Emerald.Regex`) checks all of that type,
which keeps the reasoning simple while still skipping every type a program never touches.
Values reach through `typeOf`, which every checked expression passes through; names reach
through calls and qualified names; and the program's own structs are walked first, since
printing or encoding one runs the bodies of what its fields hold, which no expression names.

Two safety nets keep the coarse rule honest. The interpreter panics, naming the body, if it
would run a prelude function, constructor, or field default the checker never saw; and a unit
test checks the whole prelude and names any problem. Planting a type error in `Stopwatch`'s
`to_string` showed both halves: `print(1)` ran without noticing, and the test failed at the
planted line.

`print(1)` went from 9.87 ms to 5.09 ms in alternating runs against `main`, and page faults
from 2,508 to 1,056: most of the time saved was the operating system's, handing out memory
that checking unreached bodies never needed. Programs that use a library keep most of the
gain (JSON 62%, dates 77%, regular expressions 81% of before).

## Startup performance, slices 3–5: measured, 2026-09-28

After slice 2, the prelude's front end (lexing, parsing, and resolving, about 2.6 ms) is the
largest part of a `print(1)`'s 5.1 ms, and checking only 0.68 ms. A counting allocator over
the checker's arena showed where checking's memory goes in a program that uses a library:
`moduleView` copies every module variable into a fresh map for every body checked, and every
branch snapshot copies it again. Giving a body only the variables it uses needs care in the
definite-assignment analysis, so it is written up in the plan rather than changed here.
Teardown measured 0.24 ms. The recorded measurements and options are in
`docs/startup-design-plan.md`.

## CSV, slice 1: native parser and writer, 2026-09-28

The first CSV slice adds `src/Csv.zig`, independently of Emerald values: it parses a leading
UTF-8 BOM, RFC-style quoted fields (including doubled quotes and embedded line breaks), Unix and
Windows line endings, and a one-grapheme separator. It retains each row’s physical starting line
for the later `CsvError` layer. The writer uses `\n`, omits a terminal line ending, and quotes
only text that would otherwise change meaning. There is deliberately no prelude declaration or
Emerald API in this commit.

`tools/csv/differential.py` generated 3,000 tables (seed 1) using Python’s writer and compared
the native parser’s JSON probe results against Python’s reader: no cases differed. An alternating
startup comparison against the binary built before this slice measured the new binary at
98.3–99.0% of the old one across five programs, ordinary machine noise rather than a startup
cost. Debug and ReleaseSafe tests, build, doc examples, formatting and whitespace checks, and
Windows/macOS cross-builds all passed with Zig 0.16.0.

## CSV, slice 2: untyped tables, 2026-09-28

`Csv.parse` now returns the table's rows as `List[List[String]]`; `Csv.parse_records` turns the
first row into ordered `Dict[String, String]` records; and `Csv.format` writes text rows. Every
CSV failure is a catchable `CsvError`, with its physical line in the `line` field whenever one
exists. Empty documents give no records. A blank header is refused as `the header has an empty
column name`; both it and duplicate headers retain line 1 without changing their approved
message wording. Conformance covers parsing, records, formatting, Unicode separators, each text
failure, and an uncaught error's diagnostic.

The pinned Zig 0.16.0 Debug and ReleaseSafe suites, build, doc examples, formatting and
whitespace checks, and Windows/macOS cross-builds passed. In an alternating 60-run comparison
with slice 1, `print(1)` was 100.6% of its former median; the language-only and dates programs
were 101.2% and 99.9%. That is ordinary host noise, not a measurable cost for a program that
does not use CSV.

## CSV, slice 3: typed decoding, 2026-09-28

`Csv.decode(text, as: List[Record], separator: ",")` is now a checker-recognized conversion;
the parser recognizes `Csv.decode` and `Emerald.Csv.decode` only. CSV validates the target as a
list of plain structs with scalar, enum, date/time, or optional fields. Cells are converted to
primitive JSON values and sent through JSON's existing recursive decoder, preserving generated
construction, defaults, optionals, private fields, enums, and date/time parsing without a second
copy of that machinery. Empty cells become optional absence, or a default by omission; unknown
columns are ignored. Conformance covers scalar conversions, bool capitalization, missing and
extra columns, defaults, optionals, dates, every listed value error, and an unsupported-field
diagnostic. JSON conformance remained unchanged.

The pinned Zig 0.16.0 Debug and ReleaseSafe suites, build, doc examples, formatting and
whitespace checks, and Windows/macOS cross-builds passed. The full test target includes the
unchanged JSON conformance cases. In a 10-run startup comparison with slice 2, `print(1)` was
98.8%, the language-only program 102.2%, dates 100.2%, regex 99.8%, and JSON 99.8% of the
previous medians—normal host variation rather than a measurable cost to programs that do not
decode CSV.

## CSV, slice 4: typed encoding, 2026-09-28

`Csv.encode(records, separator: ",")` now has the same checker-recognized boundary as JSON
encoding, but deliberately accepts only `List` values of plain structs whose public fields each
fit one text cell: text, whole numbers, numbers, booleans, enums, date/time values, or those
values made optional. The checker and runtime reuse JSON's recorded static source type map rather
than attempting to reconstruct erased list element types. The encoder writes the public field
names and values in declaration order, leaves private fields out, writes optional `nothing` as an
empty cell, and delegates quoting, LF line endings, and separator validation to `Csv.write`.
`Float` uses Emerald's existing display rules, preserving `2.0` rather than quietly turning it
into an integer-looking cell.

The focused conformance case covers enum/date/optional values, quotes and separators, private
fields, a `decode` round trip, named arguments in either order, the qualified `Emerald.Csv`
entry point, an empty typed list's header, and a catchable bad-separator error. A diagnostic case
refuses a collection-valued field. While running the full suite, the prior slice was found to
carry two stale diagnostic expectations: its file path had an extra `conformance/` prefix, and a
JSON decoder message said `Json` instead of the established `JSON`. Correcting those shared
typed-decoder expectations left JSON's cases unchanged and made the complete suite pass.

With Zig 0.16.0, Debug and ReleaseSafe tests, build, doc examples, formatting and whitespace
checks, and Windows/macOS cross-builds passed. In a 10-run ReleaseSafe comparison with slice 3,
the new binary measured 97.8–100.1% of the prior medians across `print(1)`, structs, dates,
regex, and JSON: ordinary host noise, with no measurable startup cost for programs that do not
use CSV.

## CSV, slice 5: documentation and integration, 2026-09-28

The CSV milestone is complete. `docs/library/csv.md` now documents the dynamic text-table path,
the checker-known record path, field vocabulary, blank-cell rules, line-aware `CsvError`, quoting,
separators, and output endings. `examples/csv.em` demonstrates typed spreadsheet records and
unknown columns without needing a file or command-line argument, so the documentation checker can
run it directly. The inventory, rewrite context 15.7/15.11, and its implementation decision table
now make CSV part of the settled public library rather than a plan.

`run/prelude-reach` reaches `Csv.decode` into a record containing a `Date`, proving the startup
reachability analysis includes the native-to-prelude parse path. The valid-program fuzzer also has
a CSV template that writes a typed record with named arguments, decodes it with `as:`, reads it
as string records, and executes the result under the ordinary bounded step limit. The completed
plan was removed, as the JSON and HTTP plans were once their references became normative docs.

The pinned 0.16.0 Debug and ReleaseSafe suites, build, documentation-example check, formatter
and whitespace checks, Windows/macOS cross-builds, and a 1,000-case bounded fuzz campaign all
passed. The new example and its inline reference snippet were each run against the built binary.
Against slice 4, a 10-run ReleaseSafe startup comparison measured 100.3% (`print(1)`), 101.6%
(structs), 94.9% (dates), 102.4% (regex), and 98.8% (JSON): normal host variation, not a
measurable change to programs that do not use CSV.

## Startup performance, finished: 9.9 ms to 3.5 ms, 2026-09-28

The remaining levers from `docs/startup-design-plan.md`, now removed as finished:

- **Each body gets only the module variables it uses.** The resolver records, per function
  body (keyed by its statements), every module variable used anywhere inside it, read or
  assigned, including its lambdas and nested functions; the checker's `moduleViewFor` copies
  only those, where it had copied every module variable for every body and again for every
  branch snapshot. `Checker.requireInView` panics if a body ever reaches a variable its
  record lacks, and on its first run it caught field defaults, which are checked as a body
  with no statements and so now get the whole view. Programs using a library: dates 85%,
  regular expressions 84%, JSON 94% of before.
- **Skipping cleanup at exit gained nothing** and was reverted. The frees measured 0.27 ms,
  but leaving them to the operating system measured 99–101% of the build before: reclaiming
  the same pages at exit costs about what freeing them did.
- **The prelude is parsed when Emerald is built.** `tools/prelude_ast.zig`, a build step,
  parses `src/prelude.em` with the real lexer and parser (through `src/front.zig`, which
  exposes the front end without the rest of Emerald) and writes the syntax tree as Zig
  constant data, using only anonymous literals so the generated file needs no type names;
  one reflective `emit` covers every AST type. The file is about 800 KB. A unit test checks
  it equals a fresh parse. Compile cost measured on the development machine: about 0.6 s
  more for a Debug build and about 19 s more for ReleaseSafe. Every benchmark program took
  66–76% of its time before; `print(1)` 5.27 → 3.51 ms, page faults 1,060 → 717.

Resolving the prelude's names, about 1 ms, is now the largest part of a small program's
startup, left in the handoff's rough edges.

## Base64 and hashing, slice 1: EncodingError and hex, 2026-09-28

The first small-utilities slice adds `EncodingError`, a `RuntimeError` for text encoding
boundaries rather than filesystem access. In particular, `Bytes.to_string()` no longer raises
`FileError` for invalid UTF-8: raw bytes may never have come from a file. `to_string_maybe()`
continues to report that ordinary absence without raising.

`Bytes.to_hex()` writes two lowercase digits for every byte, and `Bytes.from_hex()` accepts
either ASCII case while `from_hex_maybe()` returns `nothing` for invalid text. The raising form
names an odd digit count, or the invalid character and its zero-based Emerald character index.
Conformance constructs every byte value 0 through 255 and round-trips it, checks mixed case and
the optional form, and catches each new encoding failure. A checking case protects the ordinary
type-level `Bytes.from_hex(text: String)` signature.

Pinned Zig 0.16.0 passed the Debug and ReleaseSafe `zig build test -j1` suites, `zig build
-j1`, the documentation-example check, formatter and whitespace checks, and Windows/macOS
cross-builds.

## Base64 and hashing, slice 2: Base64, 2026-09-28

`Base64.encode` writes standard padded RFC 4648 text by default and URL-safe unpadded text
with `url_safe: true`. The matching decode methods accept either padding form and copied,
wrapped text, reject the other alphabet rather than guessing, reject impossible final bits, and
offer `decode_maybe` for ordinary validity checks. The checker names Bytes explicitly and tells
the reader of `Base64.encode("hi")` to use `"hi".to_bytes()`.

## Base64 and hashing, slice 3: digests, 2026-09-28

`Digest.sha256` and `Digest.hmac_sha256` return the raw 32-byte result, so `to_hex()` remains
the deliberate display and comparison step. The implementation uses Zig's SHA-256 and HMAC
primitives and copies their fixed result into immutable Bytes. FIPS SHA-256 and RFC 4231 HMAC
known-answer vectors protect the public boundary; the differential tool compares random inputs
with Python's `hashlib` and `hmac`.

## Base64 and hashing, review, 2026-09-28

Review found Base64 decoding walking bytes: `Base64.decode("Zm9vé")` quoted half of `é` as a
broken UTF-8 byte, at a byte index, and `ZgB=` blamed the `=` rather than the `B`. Decoding now
walks characters as hex does and keeps each character's original index. Padding that does not
fit its last group has its own message, and a character from the other alphabet names
`url_safe:` in its help. The checker's help had quoted `"hi".to_bytes()` for any argument and
suggested `to_bytes()` for Bytes given to `decode`; `Digest` had no text hint at all. The plan's
remaining known answers (one million `a`s; RFC 4231 cases 3, 4, 6, 7) and a decoding and
corruption differential were added, with no differences from Python.

## Release preparation for 0.6.0, 2026-09-28

Section 3.4 starts `else`, `catch`, and `finally` on their own lines, and the formatter writes
them so, but 36 lines in runnable conformance cases, one reference page, one plan, and a Zig
test snippet had them after the closing brace. Formatting those files wholesale was not an
option: many cases exercise layouts the formatter changes on purpose (`- 3.abs()`, `(2,)`,
parenthesized negative receivers). The lines were split by hand instead, and two tests in
`src/conformance.zig` now hold the line: one rejects `} else {`, `} catch`, and `} finally` in
runnable cases, examples, and the documentation's `emerald` blocks (an inline `if`'s
`} else value` after a block stays legal), and one requires every `examples/` file to be exactly
as the formatter writes it.

CI had failed twice on macOS Debug in `http/http-errors.em`: its 10 ms timeout request returned
the slow endpoint's reply, since on a loaded runner the client's deadline task can start more
than the reply's 250 ms late. The test server's slow reply now waits 2 s; the client abandons a
timed-out request, so the suite takes no longer.

The time-zone data was refreshed and is already IANA's latest release, 2026d.

## Emerald 0.6.0 released, 2026-09-28

The user approved the release notes, and `v0.6.0` was tagged at `51c01cc`. The release workflow
built, smoke-tested, and published the three archives with `SHA256SUMS`, and its install check
passed with `install.sh` on Ubuntu and macOS and `install.ps1` in Windows PowerShell 5.1 and 7.
The notes, set on the GitHub release, cover everything since 0.5.0: dates and times, regular
expressions, Console, JSON, HTTP, CSV, Base64 and digests, nested types, the `Emerald`
namespace, negative literals, and startup (9.9 ms to 3.5 ms). Development moved to `0.7.0-dev`.

## Console widgets, review, 2026-09-28

Review read all six commits and ran the widgets and prompts against real programs. The width
function and the layout held up: CJK text, emoji, flags, a family emoji, and combining marks all
line up, and struct tables match the plan. It fixed what a student would notice. A bad answer to
`choose` or `choose_many` reprinted the whole option list each time. The end of input inside a
prompt reported `input reached the end of the input` and suggested `input_maybe`, though the
student had called `Console.ask`; prompts now read with `input_maybe` and raise an `InputError`
that names the prompt. `ask_float` accepted `Infinity`. A numeric column's header sat at the left
over right-aligned numbers. `examples/console.em` had replaced the only runnable tour of
`Console.style`, so that example is back as `examples/console-style.em`. New conformance cases
cover each fix. Known limits are documented rather than fixed: a tab has no width, and a keycap
emoji counts as one column where most terminals draw two.

## HTTP: a timed-out request's reply reached the next request, 2026-09-28

`conformance/http/http-errors.em` failed now and then in CI, first on macOS and then on
Ubuntu: its `/redirect-loop` request returned `200 too late`, the reply of the `/slow` request
that had just timed out. A 2-second server delay did not help, because the cause was not a
late timer. A standalone reproduction (a Python server logging each request, the 0.6.0 binary,
400 runs under CPU load) failed 5 to 8 times per 400, and in every failure `/slow` reached the
server only when `/redirect-loop` should have, and `/redirect-loop` never arrived. A timeout
that canceled `/slow` while it was still being sent left its bytes in the connection's buffer,
and Zig's client returned that connection to its pool; the next request sent the stale bytes
ahead of its own and read the reply to them. `perform` now marks a connection as closing
unless its response was read completely. The fixed binary had no failures in 1,200 runs, and
`/slow` never reached the server. The unit test checks that a request after a timeout gets its
own reply; the failing window is too narrow to hit on purpose there.

## Concurrency, slice 1: a task's own state, 2026-09-29

The interpreter's execution-local fields now live together in `Scheduler.TaskState`; its
single-task baton checks that state is saved and loaded by its owner. `Streams.io` carries one
execution I/O backend into `Interpreter.io`, and filesystem operations, file closure, clocks,
and sleep use it rather than reaching for the global backend. Existing callers keep the
single-threaded default. `file_handles` and `file_writers` stay on the interpreter because they
are live resource registries whose class handles retain identity across tasks, not caches.

On Linux, an alternating 30-run ReleaseSafe comparison against `main` showed no measurable
startup cost: `print(1)` was 3.88 ms vs. 3.97 ms, and the language-only, dates, regex, and JSON
samples were 99.0%, 100.2%, 98.5%, and 99.8% of main. Full validation passed with Zig
0.16.0 `-j1` (Debug and ReleaseSafe tests, build, doc examples, formatting, whitespace, and
Windows/macOS cross-builds).

## Concurrency, slice 2: tasks with results, 2026-09-29

`Task[T]`, `Tasks.run`, `TaskGroup.start`, `result()`, and `done?()` now run through a FIFO
single-owner baton, with one OS thread per live child. A group drains all children before it
returns and propagates its first unobserved task error. Tests cover ordered results, errors,
nested tasks, a 950-call child recursion, a 64-child limit, and cyclic allocations across
suspended tasks. Task-using conformance cases were repeated 50 times each before commit.

The plan's claim that `Checker.capturesOf` tracked lambda-local captures was false: it tracks
transitive module reads of named declarations. The checker already knows a binding's
mutability and which scopes surround the current block, so it enforces direct no-`var`
capture there, including nested lambdas. The user approved requiring an inline block for
`tasks.start`; stored function values would hide their captures without an effect type.
Named calls that read a module `var`, and calls through a function value that captured a
`var`, remain known gaps for the multicore plan. They cause no data race with one baton.

ReleaseSafe measurements on Linux: 1,000 sequential tasks took 0.21 s / 11 MiB peak RSS;
10,000 took 2.62 s / 52 MiB; 64 live tasks took 0.02 s / 24 MiB; 100,000 scheduler-only
baton handoffs took 1.63 s / 1 MiB. Each live task reserves a 128 MiB virtual stack on a
64-bit host, committed only as used; the 64-task cap keeps that bounded. Windows timing
and memory still need a CI runner. Automatic sibling cancellation arrives with slice 5's
cancellation machinery; this slice drains children before propagating their errors.

## Concurrency, slice 3: time and outside work, 2026-09-29

`Tasks.yield()`, scheduler-managed sleeps, `Task.wait(timeout)`, and `DeadlockError` are
implemented. A lazy timer worker keeps deadlines ordered and breaks ties by when waiting
began. Input, filesystem operations, streamed handle operations, and HTTP release the baton
only for their host work, then reacquire it before inspecting results or changing the Emerald
heap. HTTP uses the calling task's existing thread, not an additional helper. Input and file
handles have FIFO gates; closed native records survive until teardown so queued operations
cannot refer to freed state. Task executions synchronize their backing allocator because
host I/O can allocate while another task evaluates; non-task executions keep their allocator.

A two-task probe reading the same unchanged 1,000,000-byte file, then printing inside each
task, produced `a, b` 94 times and `b, a` 6 times in 100 runs. That disproved the original
promise of reproducible output without clocks. The user approved the precise replacement:
task/channel/yield scheduling is reproducible, with ready tasks resumed in readiness order;
earlier sleep deadlines resume earlier, ties use waiting order, and only clearly different
lengths give a reliable real-clock order. File/network/input completions arrive in variable
order. The first example now teaches printing results in the wanted order (or using a channel).
The probe is retained separately from conformance; conformance never assumes I/O arrival order.

Review also found that a deadlock can become visible when the last runnable task finishes,
not only when another task begins waiting. Detection now runs at every handoff and snapshots
the original wait graph and locations before waking participants for error propagation.
Focused cases cover caught deadlocks and this late-visible case.

Full local validation passed with pinned Zig 0.16.0 and sequential `-j1`: Debug and ReleaseSafe
tests, native build, documentation examples (23 executed, 112 linked conformance files),
formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds outside `zig-out`.
Eleven new or changed task-running cases each passed 50 consecutive runs (550 total), with
HTTP using a loopback-only server; expected files were read by hand. Windows runtime behavior
and measurements still require green PR CI. Channels are the next slice.

## Concurrency, slice 4: channels, 2026-09-30

`Channel[T]` now has FIFO rendezvous and buffered sends, `receive`, idempotent `close`,
and built-in iteration. Its invariant message type is supplied by expected-type context:
annotations, parameters, returns, and collection literals. Native creation handles both
qualified and bare calls while respecting local shadowing; arguments bind by name. The
runtime uses the existing opaque class-handle pattern, with static `Type.Kind.channel`.
Thread operations remain entirely in the scheduler; native queues explicitly retain message
values so their copy-on-write semantics and collector roots are unchanged. Buffers grow on
demand and reuse consumed slots rather than retaining previous messages indefinitely.

Closing preserves buffered messages for draining, ends pending receives, and fails uncommitted
sends with RuntimeError. Negative capacity is also RuntimeError; no new error subclass was
needed. Optional receive results flatten as usual, while iteration distinguishes a message of
`nothing` from end-of-stream. Function messages retain existing closure semantics, so the
known indirect captured-variable gap for multicore includes functions passed through channels.

Deadlock diagnostics name channel numbers, send/receive direction, and original wait sites.
Review found that after a caught deadlock, another participant's obsolete waiter could still
be present until it resumed; such already-readied waiters must not accept new messages. The
runtime now checks scheduler readiness before matching them. A focused recovery case protects
this, alongside FIFO, capacities, closure, value copies, cyclic captured-closure messages,
destructuring, loop control, contextual typing, and local shadowing. No plan/source mismatch
required a new design decision.

Full local validation passed with pinned Zig 0.16.0, sequential `-j1` Debug and ReleaseSafe
tests, native build, documentation examples (23 executed, 112 linked conformance files),
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds outside
`zig-out`. All seven standalone scheduler unit tests passed. Sixteen new or changed running
cases passed 50 consecutive runs each (800 total); expected files were read by hand. Windows
runtime validation remains for green PR CI. Cancellation is the next slice.

## Concurrency, slice 5: cooperative cancellation, 2026-09-30

`Task.cancel()` requests cancellation at a suspension point. `CancelledError` extends
`Error` directly, so a RuntimeError catch cannot swallow it. Task/channel/input/timer
waits are readied cooperatively; finally blocks and group draining mask cancellation so
cleanup can itself wait. A real failure remembers the group's first error and cancels
siblings and its owner once. An owner asking for that failing task's result observes its
actual error, preserving typed catches without raising it again during draining. Other
owner suspension points raise CancelledError; the group reports its original failure
after joining all children. Explicitly cancelled children alone do not fail a group,
but their result calls raise CancelledError. Tasks started by a sibling before reaching
its checkpoint inherit the group's ongoing cancellation; otherwise a new long sleep
could keep the draining group alive after its first error was handled. Program exit
cancels and drains its tasks.
Normal implicit joining remains interruptible, including for nested groups; it becomes
protected draining only after an error or cancellation. A nested-group regression checks
that cancelling its parent stops the nested sleep and runs both levels of cleanup.
Two existing deadlock expectations now preserve the group's original failure site rather
than replacing it with a child's later failure.

Final review caught a repeated-cancellation edge: channel matching must keep a protected
cleanup waiter, even with a new cancellation request pending. The regression case cancels
again while `finally` waits to send its second message, then receives it and allows cleanup
to finish. Group draining also clears pending cancellation before restoring its original
error, so a late cleanup request cannot replace that error.

Inspection found that the raw-thread host operations and arbitrary borrowed input readers
could not be interrupted by simply readying a task. A bounded probe started an input task,
yielded, then raised `RuntimeError("stop the group")` in the owner; it remained alive with
stdin open and no data, and reported the child's InputError only after stdin closed.
The user approved a narrower solution rather than a general custom-reader contract:
Scheduler.zig owns one process-lifetime stdin reader and its allocations; a cancelled
task abandons only its registered wait, leaving the in-flight read and eventual line
for the next input call. Program exit does not join that blocked reader. Fixed services
own finite buffers and join/free at teardown; caller position advances only on delivery.
Other borrowed readers retain their previous host-read path, with no cancellation hook.

The two-task input test found a FIFO bug during development: a later caller could steal
a line promised to an earlier waiting caller. Explicit reservation fixes it, and releasing
a cancelled reservation passes the intact line onward. All reader/runtime pointers are
unregistered under the reader mutex before their task returns. The live-input driver
checks both prompt exit with stdin held open and a line supplied only after cleanup and
the first-error catch; CI runs it on every platform/build combination.

HTTP cancellation signals the existing deadline worker early, using the existing Select
race and transport cleanup instead of a second cancellation mechanism. A response that
finished concurrently is freed before raising CancelledError. The signal is shared by
child cancellation and cancellation of a group's owner after its child fails; the HTTP
case covers both directions. File operations are not
interrupted: cancellation arrives after they return, so named pipes/devices can delay it.
These distinctions are documented in the rewrite context and library references.
Managed file helpers also deliver cancellation after opening, before invoking a user
block, and close their new handle. A tmpDir-backed Zig test checks both helpers, absence
of user-block output, and subsequent file reuse.

Full local validation passed with Zig 0.16.0 and sequential `-j1`: Debug and ReleaseSafe
tests, native build, documentation examples (23 executed, 113 linked conformance files),
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds with
prefixes outside `zig-out`. Nine scheduler unit tests pass. Fifteen new, changed, or
directly affected task cases passed 50 consecutive runs each (750 checks), including HTTP
against a loopback-only server. The live-input driver passed 50 prompt-exit and 50
retained-line checks, and a local-file cancellation probe passed 50 runs. Every expectation
was read by hand. Windows execution remains a green-PR-CI gate. Slice 6 is next; the branch
has not been pushed or merged.

## Concurrency, slice 6: documentation and integration, 2026-09-30

The task/channel reference and inventory now document the complete public surface,
callbacks and direct-capture checking, scheduling, results, typed errors, cancellation,
protected cleanup, deadlocks, and current limits. Rewrite-context 15.13 records the
settled design; 15.7 and 21 no longer defer structured tasks, and section 22 records the
nine accepted decisions. Program.sleep now documents pausing only its calling task.
The handoff drops completed-slice narrative and stale Console-widget deferrals, retaining
review/CI status and the multicore capture gaps.

`examples/tasks.em` is a short, network-free tour: ordered results, buffered messages,
and cancellation with a 20 ms sleep. Its verified output is `10 20`, `total: 6`, and
`cleaning up`. It and the expanded prelude-reach case passed 50 matching runs each; the
existing prelude-reach expected file was read and remains unchanged.

The formatter already supported task/channel flags and nested type elements; a dedicated
test protects their canonical output. LSP traversal already handled element annotations
and task bodies, but the outer Task/Channel names were absent because generic AST nodes
carry flags and an empty name. Their definition/reference handling now uses the prelude
declarations through Resolver's namespace keys. Tests cover those names, element types,
hover types, and navigation inside task blocks. The queued built-in-member table remains
separate; no second completion/signature registry was introduced.

Two valid fuzz templates exercise yielded results and channel rendezvous/buffers, without
clocks or outside I/O. Correcting the template-selection range also makes the existing
inline-if fallback reachable; the former upper bound excluded it. The fixed ReleaseSafe
campaign passed seed 12648430, 1,000 cases, 136 executions.

Windows ReleaseSafe CI now builds the existing scheduler probe and runs all four cost
measurements: 1,000 and 10,000 sequential tasks, 64 live tasks, and 100,000 scheduler
handoffs. Its bounded PowerShell driver reports time and sampled peak physical memory
while each process is alive, checking output and status. Windows execution remains pending
CI, not claimed from a cross-build. The standalone probe cross-compiled successfully for
Windows; its documented command and CI explicitly set ReleaseSafe on both Zig modules.

Startup comparisons used main `ef14a72` and this branch, ReleaseSafe, alternating 60 runs
per binary/program, on Linux 6.18.33.2-microsoft-standard-WSL2, 8 CPUs. The first comparison
measured `print(1)` at 3.73 vs. 3.76 ms, with five ratios from 100.7% to 102.8%.
After the final LSP change, the comparison was:

| Program | Main median | Concurrency median | Second/first |
| --- | --- | --- | --- |
| `print(1)` | 3.67 ms | 3.76 ms | 102.3% |
| Structs (language only) | 4.09 ms | 4.12 ms | 100.7% |
| Dates | 5.22 ms | 5.28 ms | 101.2% |
| Regex | 5.76 ms | 5.85 ms | 101.6% |
| JSON | 4.49 ms | 4.50 ms | 100.2% |

These small observed differences do not establish zero overhead, but show no material
startup regression for programs not using concurrency.

The full local gate passed with pinned Zig 0.16.0 and sequential `-j1`: Debug and
ReleaseSafe tests, native build, documentation examples (24 executed, 124 linked
conformance files), changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64
cross-builds with prefixes outside `zig-out`. No accepted API decision needed changing.
All six implementation slices are ready for Claude's whole-branch review and PR; green
Windows runtime CI and its measurement results remain required before the milestone is
fully done. Codex pushes the branch, but does not merge it.

## Concurrency: required review corrections, 2026-09-30

The user identified four merge blockers after slice 6. The Windows measurement command
now quotes both module arguments and the emitted binary argument, rather than letting
PowerShell split a `.zig` path. Task threads use Windows `CreateThread` with
`STACK_SIZE_PARAM_IS_A_RESERVATION`, preserving the 128 MiB recursion budget without
committing it up front. That detail stays inside Scheduler.zig. The driver now reports
peak commit as well as working set, confirms all 64 task threads started before a child
ran, and rejects a live-task commit above 1 GiB. Actual Windows measurements await CI;
a cross-build is not a Windows runtime result.

Joined jobs leave the scheduler's active list. On group completion, results and errors
become collector-visible edges on the Task handle. A native bookkeeping finalizer removes
the record when the handle becomes unreachable; it never releases managed values while
sweeping. Active groups root handles, while escaped handles continue to provide repeated
results and errors. Group records, closures, and execution buffers are no longer retained
until interpreter teardown. Tests cover unlinking, escaped handles, and cycles through
managed native payloads. The final drain also joins a completed job when cancellation
interrupted its ordinary wait before the host thread was joined.

Measurements exposed an additional issue: the task allocator activation looked for a
method key, but prelude reachability stores the top-level `Emerald.Tasks` key. That is
corrected and tested. Simply enabling the existing allocator mutex did not stop
ReleaseSafe's host allocator retaining small buffers in separate thread-local freelists.
Nine shared size-class pools under that mutex now allow cross-thread reuse, with backing
storage bounded by peak live allocations and released at outcome teardown. Larger and
over-aligned allocations keep the caller's allocator. Tests verify reuse, alignment, and
refusal to resize across pooled/unpooled allocation classes.

Three alternating Linux ReleaseSafe samples per count measured 2,000 tasks at 0.36 s /
7.19 MiB peak RSS and 20,000 at 3.57 s / 7.19 MiB: 9.92x time, 1.00x memory. Before
pooling, reclaimed records already made execution linear, but RSS grew from about 8 to
18 MiB (about 62 MiB at 100,000 tasks); Debug was flat at 19,868 vs. 19,884 KiB. These
measurements separated allocator retention from live task state. Windows CI also checks
the 2,000/20,000 ratio for time, physical memory, and commit.

Optional channel item types now fail checking with `a channel's items can't be optional`
and `Wrap the value in a struct.` A diagnostics case protects both lines. The previous
optional-message case now uses a struct with an optional field; its expected output is
unchanged. The new expected files were read by hand.

Pinned Zig 0.16.0 local validation passed: Debug and ReleaseSafe tests with `-j1`, native
build, documentation examples (24 executed, 126 linked conformance cases), changed-Zig
formatting, whitespace, Windows x86_64 and macOS aarch64 cross-builds outside `zig-out`,
and the standalone ReleaseSafe Windows scheduler probe cross-build. All 33 task/channel
run cases passed 50 executions each. The live-input driver passed 50 prompt-exit and 50
retained-line checks. The ReleaseSafe fuzz campaign passed seed 12648430, 1,000 cases,
136 executed. Windows runtime CI and its new measurements still gate merging.

## Concurrency: Windows measurement baseline correction, 2026-09-30

PR CI for `73a6014` passed Windows Debug and the Windows ReleaseSafe suite, reaching
the repaired measurement command. It reported 1,000 tasks at 0.163 s / 9.27 MiB
working set / 1032.74 MiB commit; 10,000 at 1.306 s / 9.33 MiB / 1032.81 MiB; all
64 live task threads started, at 0.022 s / 10.93 MiB / 1035.38 MiB. The driver's
absolute 1 GiB commit assertion failed. Inspection of `emerald.zig` confirmed its
pre-existing main interpreter thread requests a 1 GiB stack through `std.Thread.spawn`;
the driver's comment had incorrectly assumed 128 MiB. The extra commit from the live
children was small, not 128 MiB per task. This was a measurement-baseline bug, not a
reason to retry CI or change a timing margin.

The driver now measures the same live-task program with one and 64 children, reports
the additional commit, and rejects more than 64 MiB for the 63 additional threads.
This isolates task stack costs and is much stricter than allowing their 8 GiB of
upfront commit. The main interpreter's existing stack policy is recorded, not changed
as an unrelated optimization. The full local gate passed for the code in `73a6014`;
this correction changes only the PowerShell measurement and its documentation. Debug
tests and whitespace checks passed again before committing; the remaining platform
jobs and fuzz campaign on `73a6014` all passed. The corrected Windows measurement
must run successfully on the next CI commit before merging.

## Concurrency: deterministic memory sampling handshake, 2026-09-30

The Windows ReleaseSafe suite passed again on `ef08906`, but the new one-task
baseline exited before PowerShell could sample its memory. The driver correctly
refused to report a zero sample. A live-process polling loop alone cannot guarantee
observing a short process, regardless of its polling interval.

The live-task probe now has an explicit sampling mode: print `started: N`, wait
for the input acknowledgement `measured`, then return the total. The driver reads
the marker asynchronously, takes its peak working-set and commit samples while
the process is guaranteed alive, and acknowledges it. One and 64 children use the
same handshake and input-reader overhead. This fixes synchronization instead of
adding a sleep, rerunning a flaky test, or widening a timing margin. The ordinary
benchmark mode remains unchanged. Both sampling modes passed 50 runs on Linux;
the tool is formatter-clean. Debug and ReleaseSafe tests, native build, documentation
examples, changed-Zig formatting, whitespace, and Windows/macOS cross-builds passed
again with pinned Zig 0.16.0 and `-j1`. Windows measurements remain pending the new
CI run.

## Concurrency: Windows runtime measurements passed, 2026-09-30

Windows Debug and ReleaseSafe PR CI on `80b493e` passed, including live-input
cancellation and the deterministic memory-sampling handshake. The measurements below
are actual Windows execution from
[PR run 36771640683](https://github.com/amortimer20/emerald-lang/actions/runs/36771640683),
not cross-build results.

| Probe | Time | Peak working set | Peak commit |
| --- | --- | --- | --- |
| 1,000 sequential tasks | 0.196 s | 9.25 MiB | 1032.75 MiB |
| 10,000 sequential tasks | 1.681 s | 9.30 MiB | 1032.81 MiB |
| One live child (sampling baseline) | 0.048 s | 9.44 MiB | 1048.74 MiB |
| 64 live children | 0.037 s | 10.96 MiB | 1051.44 MiB |
| 100,000 scheduler handoffs | 1.445 s | 3.20 MiB | 0.63 MiB |
| 2,000 sequential tasks | 0.336 s | 9.25 MiB | 1032.75 MiB |
| 20,000 sequential tasks | 3.225 s | 9.30 MiB | 1032.82 MiB |

All 64 task threads started before a child ran. The additional 63 threads cost
2.70 MiB peak commit, rather than 128 MiB each. One/64-child times include the
driver handshake, so they are not isolated thread-creation timings. Both probes
include the same input-reader overhead; the absolute commit also includes the main
interpreter's pre-existing 1 GiB committed Windows stack. That remains unchanged,
not hidden by calling commit charge physical memory or reducing a recursion limit.

The 2,000/20,000 check passed at 9.59x time, 1.01x peak working set, and 1.00x commit,
confirming linear sequential execution with bounded memory on Windows as well as
Linux. The handoff and plan now record the green Windows runtime gate. No merge was
performed; Claude still owns the final review and merge. The full PR run also passed
Ubuntu and macOS Debug/ReleaseSafe and the fixed fuzz campaign. All seven jobs are green.

## Concurrency, review and merge, 2026-09-30

Claude reviewed the scheduler and the interpreter's task paths, and ran programs against the
branch. Four problems were fixed on the branch before merging. Finished tasks were never freed:
20,000 sequential tasks took 16 s and 157 MB, and scans of `Runtime.all` made time quadratic;
now 20,000 take 9 to 10 times as long as 2,000, at the same peak. On Windows, `std.Thread.spawn`
committed each task's whole stack; task stacks are now reserved, and 64 live tasks add 2.7 MiB of
commit. The Windows measurement step had been passing its paths through PowerShell unquoted.
`Channel[T]` with an optional `T` could not tell "sent nothing" from "closed" and is refused.
Probes then confirmed the no-`var` rule (direct and nested captures), inline-only `start`, the
first error winning, cancellation running `finally` without being caught as a `RuntimeError`,
deadlock messages naming each wait, and the collector across channels and suspended tasks (500
packets of nested lists, 20 runs, none damaged). The `start` hint now names the function the
program wrote. The main interpreter thread on Windows still commits its 1 GiB stack, as before
this milestone; reserving it the same way is a small follow-up.

## Bug-fix batch, item 1: collection mutation value semantics, 2026-09-30

Branched from freshly fetched main `4c51a6c` and built that baseline with pinned
Zig 0.16.0 before reproducing the user's program:

```emerald
var a = [1, 2, 3, 4]
var b = a
a.remove_if { n => n % 2 == 0 }
print(a, b)
```

Main printed `[1, 3] [1, 3]`. The new run regression failed on main's assertion that
`b` remains `[1, 2, 3, 4]`. Main also accepted the new diagnostics program calling
`box.prune()` on a const struct whose method invokes `self.items.remove_if`.

The native used an evaluated receiver directly, bypassing the place traversal and
copy-before-change used by the other mutators. Its missing mutation metadata also
made struct effect inference mistake that method for a read-only method. It now
evaluates its block through the normal changing-call path and mutates the unique List
at its actual place; the shared method metadata marks it as changing. No new syntax,
method signature, or mutation policy was introduced.

Audited all List mutators (`append`, `insert`, `remove`, `remove_all`, `remove_if`,
`remove_at`, `remove_first`, `remove_last`, `clear`, `reverse!`, `unique!`, `sort!`,
`shuffle!`), Dict insertion/replacement/removal/merge, and Set add/remove. The other
natives already use the shared unique-storage path. The regression covers each,
plus indexed assignment, seeded Random shuffle, nested List paths, and mutation of
a struct copy. The const-struct diagnostic now rejects `prune`; both new expected
files were read by hand. Callback reentrancy is the separately requested item 13,
not claimed resolved by this copy-before-change audit.

The full required gate passed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe
tests, native build, documentation examples (24 executed, 128 linked conformance
cases), changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64
cross-builds outside `zig-out`. The handoff and release-note list record the fix
before committing it. Claude's proposed REPL plan landed on main after this branch
was created; it remains separate from this batch and no REPL code was changed.

## Bug-fix batch, item 2: required case-header grouping, 2026-09-30

Reproduced with the separately built main baseline (`4c51a6c`):

```emerald
const items = [1, 2]
case {
    when (items.any? { item => item > 1 }) {
        print("yes")
    }
}
```

Main checked this program successfully, then formatted its header as
`when items.any? { item => item > 1 } {`. Checking that output failed because the
first brace was read as the arm body. The formatter now applies its existing
control-header grouping logic to each `when` alternative, rather than printing it
as an unrestricted expression. Run and format regressions protect the exact program
and canonical output; their expected files were read by hand.

A new conformance guard formats and reparses every `.em` file under `run/`, including
all project members. There are no excluded cases. Reparse uses the frontend's own
large-stack path, so deep regression programs do not depend on the test runner's
platform-default stack. No new grammar or canonical style was chosen.

The focused program runs and remains formatter-clean. The full required gate passed
with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests, native build,
documentation examples (24 executed, 128 linked conformance cases), changed-Zig
formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds outside
`zig-out`.

## Bug-fix batch, items 3 and 4: comment boundaries, 2026-09-30

Both reproduce on the separately built main baseline (`4c51a6c`). Item 3's program:

```emerald
var x = 1 ## note
var y = 2
print(x, y)
```

Main reports `expected the end of the line, found var` at the second declaration.
Emitting a documentation token had replaced the lexer's previous code-token kind,
so the following newline no longer terminated the statement. Documentation tokens
now leave that continuation state alone. Lexer tests cover termination, operator
continuation, and grouped continuation; the run regression also covers a commented
return and prints `1 2`, `3 3`, and `42`.

Item 4's program:

```emerald
case {
    when true {
        print("yes")
    }
}
# This belongs after the case.
print("done")
```

Main's formatter moves the comment inside the case's closing brace. The parser had
included the statement-ending newline in the case's source span, allowing trivia
starting immediately after that newline to be consumed inside the case. The span
now ends at the actual closing brace, before consuming the terminator. The format
regression covers inside, following, and closing-brace comments; main's format check
fails on it and the fixed binary leaves it unchanged. These closely related fixes
preserve settled comment semantics, with no new syntax choice. Both expected files
were read by hand.

The focused programs pass. The full required gate passed with pinned Zig 0.16.0
and `-j1`: Debug and ReleaseSafe tests, native build, documentation examples
(24 executed, 128 linked conformance cases), changed-Zig formatting, whitespace,
and Windows x86_64/macOS aarch64 cross-builds outside `zig-out`.

## Bug-fix batch, item 5: project Math wins, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`) with a project:

```emerald
# main.em
print(Math.sin(1))
print(Emerald.Math.sin(1))
```

```emerald
# math/functions.em
func sin(value: Float): Float {
    return value + 100
}
```

Both calls printed `0.8414709848078965`, instead of the project's call printing
`101.0`. Resolution already selected the project declaration, but its `Math.sin`
key was identical to the native key and the native checker/interpreter dispatch
claimed it. Native Math functions and constants now use keys under the reserved
`Emerald` namespace, distinct from every project key. This fixes the collision at
its source rather than reordering one call-site dispatch. Ordinary native Math
signature checking continues to use the same shared Resolver helper.

As expressly requested in item 5, hiding Math uses the usual built-in shadowing
warning. The rewrite-context's warning list records Math alongside the language's
own built-ins; standard-library namespace hiding remains otherwise unchanged.
Run and diagnostic project regressions cover the project's function and constants,
explicit native qualification, and the warning. Both expected files were read by
hand. The focused output is `101.0`, `10`, `20`, `project cosine`, `0.0`, `true`,
`true`. The String-taking project `cos` also ensures the user's signature remains
usable. Main prints native values for the minimal repro; checking the complete
regression on main reported no problems, so that check alone did not detect the
wrong native dispatch.

The full required gate passed with pinned Zig 0.16.0 and `-j1`: Debug and
ReleaseSafe tests, native build, documentation examples (24 executed, 128 linked
conformance cases), changed-Zig formatting, whitespace, and Windows x86_64/macOS
aarch64 cross-builds outside `zig-out`. Items 1–4 were pushed as a validated
checkpoint on `codex/bug-fixes`; no merge was performed.

## Bug-fix batch, item 6: counting-shaped user methods, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`):

```emerald
class Counter {
    func times(block: func(Int)) {
        block(42)
    }
}
Counter().times { number => print(number) }
```

Main reports `counting works with whole numbers, but this is Counter`. The checker
and interpreter both selected counting by spelling before resolving the receiver
or method. Counting recognition now happens after receiver checking, so user types
keep ordinary method lookup, including inherited methods. The already-checked
receiver is passed into counting validation rather than typed again. Iterables are
checked through their ordinary expression types; execution excludes resolved
methods and namespace functions from the native counting shortcut, including their
adapter chains. This prevents treating a user's returned List as a Range or trying
to interpret a custom Range-producing method as a primitive range constructor.

The run regression fails on main and passes with the fix. It covers all three
trailing-block spellings, inheritance, a struct method returning a List, List
reversal after that method, a custom Range followed by a native step adapter, and
the unchanged primitive counting block forms. Its expected output was read by
hand. No method naming or counting-language rule was changed.

The focused regression passes. The full required gate passed with pinned Zig
0.16.0 and `-j1`: Debug and ReleaseSafe tests, native build, documentation examples
(24 executed, 128 linked conformance cases), changed-Zig formatting, whitespace,
and Windows x86_64/macOS aarch64 cross-builds outside `zig-out`.

## Bug-fix batch, item 7: catchable recursion failures, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`):

```emerald
func forever(n: Int): Int {
    return forever(n + 1)
}
try {
    print(forever(0))
}
catch error: RuntimeError {
    print("caught RuntimeError: #{error.message}")
}
```

Main prints `caught RuntimeError: too much recursion calling ` followed by
backtick-quoted `forever`; checking the new specific catch on main reports that
`RecursionError` is not a type. The prelude now declares `RecursionError` as a
`RuntimeError` subclass. Both the call-depth limit and stack-space boundary use the
same native recursion-failure helper, which constructs this typed error directly
without making another Emerald call at the boundary. Its message and help are
unchanged, while the uncaught diagnostic now names `RecursionError`.

The new run case catches the specific type in the main program and across a task
result/group failure, verifies `finally`, and confirms a RuntimeError catch still
handles it. Prelude reach checks cover explicit construction and subclass identity.
Existing unbounded-call and constructor-recursion golden files, and the Zig trace
test, now require the specific error prefix without changing their 1,000-frame
checks. All three affected expected files were read by hand. The library reference,
handoff error-type list, and release notes record the shipped behavior promised
by rewrite-context 7.2; there is no new language decision.

The focused main/task regression matched its expected output in all 50 runs. The
full required gate passed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe
tests, native build, documentation examples (24 executed, 130 linked conformance
cases), changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64
cross-builds outside `zig-out`.

## Bug-fix batch, item 8: report argument errors once, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`):

```emerald
print(Json.encode(1 + true))
print(Csv.encode(1 + true))
print(Base64.encode(1 + true))
print(Digest.sha256(1 + true))
print(Console.table(1 + true))
```

Main reports each addition error twice. The required audit also reproduced duplicate
receiver errors in this changing trait default:

```emerald
trait Counter {
    var count: Int

    func bump(amount: Int) {
        self.count += amount
    }
}
Counter.bump(1 + true, 1)
```

Argument binding/checking already
records each expression's inferred or contextual type; the extra encoder,
cryptographic-input, table-row, and changing-receiver validations now read that
record instead of typing the expression again. An already-invalid trait receiver
also no longer creates a misleading secondary class/struct mutation diagnostic.
This is local reuse after argument checking, not global memoization across narrowing
or inference contexts. Existing named binding and typed-call callee metadata remain
unchanged.

The diagnostics regression fails on main and now reports exactly one error for each
of its eleven invalid expressions, covering JSON/CSV, all Base64 entry points, both
Digest entry points (including named `key:`), Console.table, and trait receiver and
parameter arguments. A run regression checks a valid explicit changing trait-default
call with a named argument. Both expected files were read by hand.

Focused checking and execution pass. The full required gate passed with pinned
Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests, native build, documentation examples
(24 executed, 130 linked conformance cases), changed-Zig formatting, whitespace,
and Windows x86_64/macOS aarch64 cross-builds outside `zig-out`.

## Bug-fix batch, item 9: readable prelude call names, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`) with
`print(Json.parse(5))`: the parameter error names `Emerald.Json.parse`. The same
minimal wrong-type call with Json.decode, Csv.parse, File.exists?, Console.red,
Date.parse, and Http.get exposes their internal prefix too. Wrong arity and unknown
named arguments have the same leak, while Digest previously stripped it on its own.

The resolver's shared display-key helper now omits the prelude namespace, after
removing private-file qualification and before turning method separators into dots.
Lookup keys themselves stay untouched; project namespace qualification stays visible.
Generic checker call messages therefore share one formatting rule, and Digest uses
that helper instead of its separate prefix/separator manipulation. Unit tests cover
native functions, nested/private prelude members, ordinary project namespaces, and
private project names.

An explicitly qualified built-in taken as a value still suggests its qualified call:
bare `print` may be the program's own function. The existing built-in-shadowing
expectation remains unchanged, preserving a correct recovery hint rather than
stripping qualification the user actually needs. Shadowing-help escape paths such
as `Emerald.File.read` also remain qualified. The new diagnostic case covers the
seven libraries, Digest, wrong arity, unknown parameters, a named option, explicit
qualification, and native Math arity. Bytes.from_hex's old prefix and Regex.Match's
nonconstructible-type display expectations now use bare names too. All three changed
expected files were read by hand.

The focused diagnostics match the intended text. The full required gate passed
with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests, native build,
documentation examples (24 executed, 130 linked conformance cases), changed-Zig
formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds outside
`zig-out`.

## Bug-fix batch, item 10: explain JSON's constructor restriction, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`) with this program:

```emerald
struct Score {
    const value: Int

    constructor(value: Int) {
        self.value = value
    }
}

print(Json.decode("{\"value\": 5}", as: Score))
```

The old diagnostic said only that Score cannot be read from JSON, followed by
the general accepted-type list. The shared eligibility result now carries the
specific custom-constructor reason from JSON's existing check; the typed-call
diagnostic explains that JSON builds through a generated constructor and suggests
decoding a plain struct before calling the custom constructor. There is no change
to which types JSON or CSV accepts, and no duplicated checker or decoder path.

The new diagnostics regression covers direct, optional, list-contained, and
nested-field occurrences of Score. Its output was compared with both binaries,
and its expected file was read by hand. The first Debug gate found one missing
space in the hand-written diagnostic caret lines; correcting that expectation
made the Debug gate pass. Focused checking passes; the remaining full required
gate also passed with pinned Zig 0.16.0 and `-j1`: ReleaseSafe tests, native build,
documentation examples (24 executed, 130 linked conformance cases), changed-Zig
formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds outside
`zig-out`.

## Bug-fix batch, item 11: preserve closing braces during recovery, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`) with the user's
minimal program:

```emerald
func f() {
    x =
}
```

It reports the missing expression at `}`, then incorrectly reports that the
function's block is never closed. Statement recovery unconditionally consumed a
closing brace at its starting position, treating it as a stray file-level brace
even when called inside a body. Recovery now takes its file/body context from
its caller: file-level recovery still consumes a stray brace to make progress;
ordinary blocks, lambda blocks, and type bodies leave their closing brace for
the enclosing parser. No diagnostics are suppressed and no syntax changes.

The new diagnostic regression fails on the main baseline and now reports only
the real missing expressions in a function, nested block, statement lambda, and
struct field. It also checks a genuine stray brace and an actually unclosed
function after those errors, so recovery must preserve both later scope and
independent diagnostics. The expected file was read by hand. Focused checking
passes. The full required gate passed with pinned Zig 0.16.0 and `-j1`: Debug
and ReleaseSafe tests, native build, documentation examples (24 executed, 130
linked conformance cases), changed-Zig formatting, whitespace, and Windows
x86_64/macOS aarch64 cross-builds outside `zig-out`.

## Bug-fix batch, item 12: reject native Math function values, 2026-09-30

Reproduced on the separately built main baseline (`4c51a6c`) with
`const f = Math.sin`: checking reports `No problems found`. Math functions reach
the qualified-value checker without a declared signature, so the old fallback
returned an invalid type silently rather than explaining the unsupported capture.

The qualified-value checker now uses Resolver.mathFunction to reject only resolved
native Math function keys, with Program.sleep's built-in-function message shape
and help suggesting a numerical call or block wrapper. The help preserves the
written path, so an explicit `Emerald.Math` path stays correct when a project owns
Math. Constants are handled before the new check; project functions have different
keys and retain ordinary function-value behavior. Native routing, member names,
argument checking, and hint vocabulary do not change.

The diagnostics regression covers sin, explicit Emerald.Math.cos, the two-argument
arc_tan2, and Program.sleep's unchanged diagnostic. A run case verifies typed
one- and two-argument wrappers and Math constants; the existing project-shadowing
case now captures and calls the project's sin. Expected files were read by hand.
The Math reference documents the restriction and links the wrapper example.
The first gate caught an incorrect source accessor in the path-preserving help;
it was corrected to read the current project file. The full required validation
gate then passed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests,
native build, documentation examples (24 executed, 131 linked conformance cases),
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
outside `zig-out`.

## Bug-fix batch, item 13: callback-safe list operations, 2026-10-01

Reproduced on the separately built main binary (`4c51a6c`):

```emerald
var items: List[Item] = []

class Item with Equatable {
    const id: Int

    @override
    func equals(other: Item): Bool {
        for n in 0..<100 {
            items.append(Item(n))
        }
        return self.id == other.id
    }
}

items.append(Item(1))
items.append(Item(2))
items.remove(Item(9999))
print(items.count)
```

It aborts with `switch on corrupt value` in Value.equals, reached from
Interpreter.mutateList's remove loop. A second probe imported an untouched archive
of main's source and called emerald.run with std.testing.allocator in a filtered
Zig Debug test. It reproduces the same panic and abort; no library implementation
was changed for either probe. The callback reallocates the ArrayList that the
outer loop is still iterating.

The user approved a mutation-only guard: reads must see the original list,
mutation must raise catchable RuntimeError naming the list and method, and value
copies must remain independent. Unlike the changing-struct guard, this leaves the
receiver available for reads. The implementation protects bindings or shared
class fields, checks writes before COW/assignment, and prepares changing callback
operations in scratch storage before a single successful publication. Removal
and deduplication decisions finish before compaction, so raised callbacks leave
scratch ownership valid too. Guard entries are shared across tasks under the
baton and can be removed out of order if callbacks yield.

Focused cases cover equality, ordering, key-building, all list mutation routes,
local/module bindings, nested functions, indices, class aliases, independently
changed value copies, and failures after earlier matching or sorting decisions.
A Zig test repeats the reallocating class-equality reproduction with the testing
allocator and verifies recovery. Golden files were read manually. The baseline
storage-path case fails by observing intermediate changed data.

The first full Debug gate found that guarding ordinary traversal callbacks was
too broad: existing Zig and conformance tests explicitly allow each/reduce to
change their source while traversing a snapshot. Those guards were removed;
the new restriction applies to equality/hashing/ordering operations and remove_if,
not ordinary traversal. A later test-only constructor call was corrected to
Random(1), matching its existing required seed. The complete gate passed with
pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests, native build,
documentation examples (24 executed, 135 conformance links), changed-Zig
formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds with
prefixes outside `zig-out`.

## Bug-fix batch, item 15: reserve the main Windows stack, 2026-10-01

Reproduced from main's successful Windows ReleaseSafe CI measurement (`4c51a6c`):
the one-live-task benchmark reported 1,048.75 MiB peak commit, despite only
about 9.47 MiB physical working set. Zig 0.16's `std.Thread.spawn` source
confirms that its Windows `NtCreateThreadEx` call supplies `stack_size` as the
committed stack size. Emerald had used that call for its three 1 GiB-stack
pipeline threads, while Scheduler's task threads already used `CreateThread`
with `STACK_SIZE_PARAM_IS_A_RESERVATION`.

Scheduler now exports one `ReservedThread` helper. It copies its arguments into
a small page-allocated context on Windows, frees that context in the child, and
uses `CreateThread` with the reservation flag; non-Windows keeps `std.Thread.spawn`.
The three frontend/interpreter call sites and task jobs use it, so their existing
stack budgets are unchanged. A scheduler unit test verifies copied arguments and
join behavior. The Windows measurement now requires the kept-alive one-task
baseline to stay at or below 128 MiB of commit, a threshold the old 1,049 MiB
implementation fails before task-thread cost is considered. Debug and ReleaseSafe
tests, including a Windows-targeted Scheduler compile, pass locally. The full
gate passed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe tests,
native build, documentation examples (24 executed, 135 conformance links),
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
with prefixes outside `zig-out`. Windows CI run `36873845746` was green on every
platform. Its ReleaseSafe measurement reported 22.67 MiB baseline commit and
25.37 MiB with 64 live tasks (only 2.70 MiB more), and printed the reservation
confirmation; this replaces the old 1,048.75 MiB main-thread baseline.

## Bug-fix batch, item 17: CRLF file lines, 2026-10-01

Reproduced against a separately built current main (`a191cf3`) with a file
containing `"first\r\nsecond\r\n"`: `File.read_lines` gave
`["first\\r", "second\\r"]`, and streamed `read_line` returned the same
trailing carriage returns, while `String.lines` gave `["first", "second"]`.

`fileLines` now trims terminal carriage returns exactly as `strings.lines` does,
and `readStreamBytes` shrinks its line-only result after the same trim. Binary
`read_bytes` keeps raw bytes. The local implementation also adopts main's
just-landed corrected line-count loop: an empty file produces no lines and a
blank line before a trailing newline is retained. Whole-file and streaming
conformance cases, plus the existing temporary-directory Zig streaming test,
cover CRLF behavior. The full gate passed with pinned Zig 0.16.0 and `-j1`:
531 Debug and 531 ReleaseSafe tests, native build, documentation examples,
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
with prefixes outside `zig-out`.

## Bug-fix batch, items 14, 16, 18, and 19: verified documentation findings, 2026-10-01

Item 14 did not reproduce against the built current-main binary. This program:

```emerald
Base64.unknown("text")
Digest.unknown("text")
File.unknown("text")
Directory.unknown("text")
Path.unknown("text")
```

produced five checker diagnostics that each say the relevant namespace has no
type-level member named `unknown`; none reached native dispatch, fell through,
or crashed. No routing change was warranted.

Item 16 reproduced by comparing the HTTP reference page with `Http.zig`: a
body-bearing redirect is returned without being followed, while `strict` still
raises only for its 4xx or 5xx status. The page now says that rather than
claiming strict mode raises for every redirect.

Item 18 reproduced by comparing rewrite-context 18.5 with `Lsp.onCompletion`:
completion already handles value members, type-qualified members, namespaces,
and bare names. Section 18.5 now says so, while retaining the handoff's
narrower warning that native built-in members are still shallow.

Item 19 did not reproduce. A case-insensitive search of this handoff for
`Console`, `design`, and `widget` found the implementation status and the
historical design/review notes consistently describe tables, panels, and
prompts as already implemented. No text change was appropriate for that item.

This documentation-only commit passed the full local gate with pinned Zig 0.16.0
and `-j1`: 531 Debug and 531 ReleaseSafe tests, native build, 24 documentation
examples with 135 linked conformance files, whitespace, and Windows x86_64/macOS
aarch64 cross-builds with prefixes outside `zig-out`.

## REPL slice 1: parsing an entry structurally, 2026-10-01

`Lexer.tokenizeFrom` now lexes a source tail from a committed entry boundary,
retaining source-global token spans. Lexer results explicitly mark an unclosed
block comment or multiline string at end of input. `Parser.parseEntry` retains
top-level expression statements (including calls), marks them for later REPL
echo handling, and explicitly marks an incomplete delimiter, block, `case`, or
lambda. Ordinary `Parser.parse` and file behavior are unchanged: a non-call
expression remains a section 5.2 diagnostic.

The REPL classifier now consumes those flags and statement metadata instead of
matching diagnostics such as "this result is never used" or "never closed".
An incomplete flag is deliberately structural: an open delimiter is incomplete,
but `var value =` is an immediate syntax error. The initial tail lexer assumes
the tail starts after a committed entry's newline, so its delimiter state starts
clean; the session representation in slice 2/3 preserves that invariant.

Focused lexer and parser tests cover global tail spans, lexical incompleteness,
open call/list/block/lambda/case forms, a malformed top-level assignment, and
both pure and call expression statements. Full validation is recorded with the
slice commit: pinned Zig 0.16.0 with `-j1`, Debug and ReleaseSafe test suites,
native build, 24 documentation examples with 134 linked conformance files,
changed-Zig formatting, whitespace, and Windows x86_64/macOS aarch64 cross-builds
with prefixes outside `zig-out`.

## REPL slice 2: persistent interpreter session

`Interpreter.Session` now owns the REPL's long-lived heap, module scope, native
resources, scheduler, and root task. Each accepted whole-session analysis is installed before
any entry executes: all checker/resolver tables are replaced together, then only that entry's
new declarations are registered and its statements run. `Analysis` consequently owns its
complete file/program view, and the coming REPL retains every accepted analysis/source so
runtime values never point into freed syntax trees.

The ordinary one-shot interpreter path remains unchanged. A session uses the scheduler's
shared allocator from its first entry, rather than trying to change allocation domains if a
later entry names `Tasks`. A runtime failure removes declarations and module bindings introduced
by its entry; prior output, assignments, and outside effects intentionally remain. Direct
testing-allocator coverage exercises a struct value and closure across analysis replacements, a
type declared after a value using an earlier type, and a raised entry followed by a legal reuse
of its dropped declaration.

## REPL slice 2 correction: retain syntax nodes, replace facts, 2026-10-01

The initial slice 2 commit `b9e5804` failed locally and in all six platform CI
jobs. Its test reparsed the entire session for every entry, so a retained closure
pointed at its original lambda node while the current analysis contained facts
for a different node. The lookup in `closureCallable` panicked. The previous
validation claim was wrong: command outputs were printed without the returned
process-session IDs, and unfinished test runs were treated as successful checks.
This correction inspects final exit codes and build summaries for every run.

`SessionSyntax` now parses each tail once with slice 1's offset lexer and entry
parser, retaining the original trees and source snapshots. `analyzeSession`
resolves/checks a program assembled from those same statements. Tests install
the replacement analysis and immediately free the previous analysis; old facts
cannot conceal a missing current-node entry. This also exposed resolver-owned
name strings in runtime tables and captured methods. Sessions now intern those
keys in their own arena.

The requested regression calls an earlier lambda, a captured private function,
and a captured method, and constructs an earlier struct through those values.
Its function and method bodies create further lambdas, exercising facts inside
older bodies too. The existing persistence/rollback test now uses the same
parse-once path. Both use `std.testing.allocator`, with obsolete analyses freed
before the later calls run. Slice 3 remains unstarted pending review.

Validation completed with pinned Zig 0.16.0 and `-j1`: 537/537 tests in both
Debug and ReleaseSafe (final command exit status 0), native build, 24 executable
documentation examples and 134 linked conformance files, changed-Zig formatting,
`git diff --check`, and Windows x86_64/macOS aarch64 cross-builds with prefixes
outside `zig-out`. Branch CI must be green before handing this correction back.

## REPL slice 2 correction: code escaping a failed entry, 2026-10-01

Review found another ownership hole: a failed entry can assign its lambda into an
earlier `var`, and decision 2 preserves that assignment. Dropping its statements
then replacing its analysis left the lambda with no checker facts. The exact
`action(2)` regression reproduced the `closureCallable` null-lookup panic under
Debug before the fix (537/538 tests passed, one crashed).

Session analyses now have stable heap-owned addresses. `ownedSessionAnalysis`
transfers their ownership to the interpreter: replacement releases obsolete
successful analyses, while each failed analysis remains until teardown. A failed
entry also archives its runtime declaration tables, so an escaped instance's
methods and constructors stay callable after their names disappear or are reused.
The shared module bindings still preserve assignments and other completed effects.

Closures, nested-function closures, runtime struct descriptors, and callables
identify their declaring entry by its source offset. Every call selects that
failed entry's retained view or the current view for kept code, restoring its
caller afterward. Constructors and defaults follow the same rule, and the view
travels with the task when the scheduler hands back the baton. Prelude bodies
need the calling analysis because they are checked lazily; a helper reached
only by failed-entry code can have no facts in the current analysis.

`SessionSyntax.dropLast` now excludes statements without truncating source text.
Later entries start after dropped text, keeping span-keyed nested-function facts
unique. Three new testing-allocator regressions cover the exact `20` result,
escaped nested functions returning through kept code, the formerly colliding
nested-function spans, task yields between views, lazy `Console.green` calls,
and a trait-backed escaped instance/captured method constructing its old type
after that name is redeclared. Slice 3 remains unstarted pending review.

Final validation completed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe
test suites passed (540 tests each, final exit statuses 0), native build, all 24
executable documentation examples and 134 linked conformance files, changed-Zig
formatting, `git diff --check`, and Windows x86_64/macOS aarch64 cross-builds with
prefixes outside `zig-out`. The corrective commit is pushed separately; branch
CI is checked before reporting completion to the user.

## 2026-10-01 — REPL slice 3 timing conflict (partial work, not committed)

The user approved slice 2 at `94705cb` and requested slice 3, adding two supplied
review probes and replacing the linear origin scan with binary search. Both
probes are now testing-allocator regressions: the escaped failed-entry lambda
prints `20`, and failed-entry code returning through a later lambda and struct
method prints `1070 20`. The origin lookup uses an upper-bound search; its new
test covers 1,000 ordered entries, their start/end boundaries, gaps, an empty
index, and another file.

Before replacing the CLI loop, a temporary ReleaseSafe test measured the
persistent-session path at entries 5 and 500. Each entry declares a new
`const job_N = { => 1 }`; page allocation and the monotonic clock avoid timing
the testing allocator's accounting. The timer includes append, analysis,
installation, and execution, but not constructing the initial session. Only
the new statement executes. The first build's probe took 5.910/36.881 ms.
Three further runs of the compiled unit-test artifact, each exiting 0,
measured totals of 5.858/22.071, 4.153/23.143, and 4.196/21.417 ms.
Median entry-5/entry-500 totals: 4.196/22.071 ms (5.26x). Execution alone took
0.004–0.007 ms in the confirming runs. Both review regressions passed on all
three runs. The temporary printing probe was removed after measurement.

This conflicts with the plan's constant total-entry latency requirement, not
with its no-replay behavior: checking the full kept program necessarily costs
more as statements accumulate. Binary-searching origins cannot remove that
analysis cost, and an incremental checker is explicitly outside the milestone.
The executor stopped for approval rather than silently changing the timing
criterion or implementing an incremental checker. The plan and live handoff
record the blocker. No new command loop/transcripts, commit, push, or slice 3
CI claim has been made. Toolchain verification passed on pinned Zig 0.16.0;
the standalone origin-lookup boundary test passed in Debug with the testing
allocator (1/1), as did changed-Zig formatting and `git diff --check`. The full ReleaseSafe
build/test gate was interrupted (exit 130) after the timing measurements
established the blocker; the full final-tree validation gate is not complete.

## 2026-10-01 — REPL slice 3: the persistent command loop

The user approved correcting the conflicting timing criterion: execution stays
flat, full-session analysis is measured rather than asserted in CI, and entry
500 must analyze in under 100 ms on this machine. Decision 1 still requires
full-session rechecking; no incremental checker or cached prelude analysis was
introduced. Slice 4 remains unstarted, pending the user's slice 3 review.

`Repl.zig` now keeps one interpreter and syntax store instead of replaying the
program and its recorded input. Only newly submitted statements execute.
Expressions echo through their original checked AST nodes; strings are quoted,
`Nothing`-typed calls are silent, and optional results may echo `nothing`.
`:reset` replaces the interpreter and syntax without replacing the shared
scheduler-owned reader. Both prompt input and program input, including inside
`Tasks.run`, use that reader. The process-owned CLI reader is not joined on exit;
finite testing readers are joined/freed under `std.testing.allocator`.

Diagnostics and trace frames map to their own entry's lines, even across calls
into failed-entry code. Only top-level redeclarations get the reset hint; prior
user warnings are not repeated on every recheck. Real-loop testing exposed two
slice 1/2 omissions: open type bodies lacked the interactive incomplete flag,
and session programs omitted `using` aliases. Both now work without changing
file diagnostic wording. Rejected syntax keeps its text and unique offsets,
but adds no statements or aliases. The two supplied review probes and the
binary origin-index boundary regression are included.

Nine hand-read transcript expectations cover echo, persistence, errors/reset,
declaration rollback, escaped code, multiline forms, aliases, EOF, and shared
input. Every conformance gate checks each transcript 50 times consecutively.
The actual built CLI also matched all 450 process runs, with no retries. A
separate testing-allocator regression repeats 50 file-append sessions and
checks the file after interpreter teardown, proving the effect occurs once.

The execution assertion alternates 31 paired samples at entries 5 and 500,
excluding analysis. It passed in both Debug and ReleaseSafe. The standalone
`repl-benchmark` profiles nine warmed ReleaseSafe samples at each prefix; final
median analysis/resolve/check times in milliseconds were:

| Entry | Analysis | Resolve | Check |
| --- | --- | --- | --- |
| 5 | 2.347 | 1.128 | 0.770 |
| 100 | 3.478 | 1.162 | 1.836 |
| 500 | 13.240 | 1.568 | 11.107 |
| 1000 | 34.156 | 2.064 | 31.518 |

Entry 500 is below the approved budget. Checking accounts for about 84% of its
analysis; resolution grows much less. The prelude's compiled AST is reused,
but its names, type/trait metadata, and signatures are rebuilt on each entry.
Bodies reached by kept user code are checked again; unreached bodies stay lazy.

Final validation passed with pinned Zig 0.16.0 and `-j1`: Debug and ReleaseSafe
test suites (546 tests each, exit 0), native build, 24 executable documentation
examples and 134 linked conformance files, changed-Zig formatting,
`git diff --check`, and Windows x86_64/macOS aarch64 cross-builds using prefixes
outside `zig-out`. Slice 3 is committed/pushed separately; its branch CI must
be green before it is reported complete. No merge or tag, and no slice 4 work.

## 2026-10-01 — REPL slice 4: documentation and integration with main

Slice 3 (`e03cb64`) passed all seven branch CI jobs before this slice began.
At the user's request, fetched origin and merged `origin/main` into `codex/repl`
as `0955c9d`, without rebasing, amending, or force-pushing. All seven main
commits merged cleanly: File.append's create-if-missing behavior (PR #29),
the accepted editor-intelligence plan, and the board-target, microcontroller,
batteries-included, and parenthesis-free-header-block handoff notes remain.
No conflict resolution or API improvisation was needed.

Added `docs/language/repl.md` and its guide-index entry. It teaches persistence,
call results and quoted strings, multiline input, redeclaration, reset, shared
input, and the difference between checking errors and runtime failures.
Rewrite-context changes are confined to 18.4 and the implementation-decision
table in section 22: a persistent interpreter replaces replay, while analysis
still rechecks the whole kept program. The design plan's old replay description
is explicitly historical. Existing slice history stays in this journal; the
handoff now has a compact completed-milestone status and new REPL release notes
beside, not duplicating, main's File.append, CRLF, User-Agent, Console, and tasks
entries. Final review/merge remains with the user and Claude.

The append demonstration needs no setup file. Its testing-allocator regression
now resolves the temporary directory's path and starts each of 50 sessions
with a missing `log.txt`, deleting it only after verifying the result is `x`.
This exercises creation and no replay together. The nine existing transcript
inputs/expectations are unchanged, as is main's new `file-append-creates` case.
Checker.zig and Lsp.zig were not touched.

Post-merge validation passed with pinned Zig 0.16.0 and `-j1`, with final exit
statuses checked: Debug and ReleaseSafe suites (546 tests each, including
50 consecutive runs of every transcript in each gate), native build,
`bash tools/check-doc-examples.sh` (24 executable examples and 134 linked
conformance files), `zig fmt --check build.zig src/*.zig tools/*.zig`,
`git diff --check`, and Windows x86_64/macOS aarch64 cross-builds with prefixes
outside `zig-out`. The built CLI independently matched all nine transcripts
50/50 each (450 processes, no retries). All three new guide transcripts were
verified, including the fresh file containing exactly `x` and the runtime
error's entry-relative `repl:4:5` location with `score` still 7 afterward.

Slice 4 is committed and pushed separately after the merge. Branch CI is
checked before reporting completion; no merge to main or tag is performed.

## 2026-10-02 — Diagnostic polish: revised Boolean naming decision

The user dropped item 11's missing-`?` warning entirely. A Bool result can report
the success of an action, so forcing `save?` would teach a misleading name.
Rewrite-context 3.3 and the section 22 decision table now record the one-way
rule: a `?` name must return plain Bool, but returning Bool does not require
that suffix. Item 12's type error still applies everywhere, overrides and the
prelude included. Casing warnings exclude the prelude and overrides; warn at
the original program declaration instead. Orphaned-doc warnings also exclude
the prelude. These exemptions are recorded with their normative rules.

The branch was clean when the decision arrived. No missing-suffix implementation
or cases had been added, so there were no `equals`/`ready` warning cases to
remove. Added `conformance/run/bool-action-name` for `func save(): Bool`, with
the hand-read expectation `true`, and linked it from the core language guide.
The handoff no longer calls `is_ready(): Bool` a missing-suffix gap. It also
reflects that the REPL has merged through PR #30 (`01125eb`), rather than still
waiting for review; the completed slice history remains above.

Validation on pinned Zig 0.16.0: toolchain check, native `zig build -j1`,
focused `emerald check` (no problems) and `run` (`true`), Debug
`zig build test -j1` (546 tests, exit 0), doc-example check (24 executed
examples and 135 linked conformance files), and `git diff --check` passed.
No checker/resolver implementation changes are included in this decision
update. Items 7–12 remain to implement; the website output check belongs to
the completed group C implementation, not this documentation-only policy
change plus its regression. Changes are uncommitted on `codex/diagnostic-polish`.

## 2026-10-02 — Diagnostic polish item 1: foreign logical operators

Reproduced `print(true && false)` and `print(true || false)` before changing
code: each operator produced two generic character errors. The lexer now consumes
each invalid pair as one token and gives one correction to `and` or `or`.
This belongs in the lexer because neither character is an Emerald operator;
strings, comments, and single invalid characters retain their existing behavior.
The diagnostics conformance expectation was read by hand, and a lexer unit test
covers diagnostic counts, spans, hints, and unaffected string/comment contents.

The complete gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe
`zig build test -j1`, native build, documentation examples (24 executed;
135 linked conformance files), changed-file formatting, `git diff --check`,
and x86_64 Windows/aarch64 macOS cross-builds with prefixes outside `zig-out`.
An initial test compile exposed a local name shadowing the file's `testing`
binding and an unnecessary optional unwrap; both were corrected. The next
build exhausted the 3.8 GB `/tmp` filesystem, confirmed by `df`; its task-owned
cache was moved intact into the workspace cache, and the full gate then passed.
No failed test was retried without identifying and correcting the cause.

The standalone Boolean-naming decision was committed as `3f7d694` and pushed
before implementation, as requested. Item 2 follows this commit; group A will
be pushed and checked in CI before review, with groups B and C still pending.

## 2026-10-02 — Diagnostic polish item 2: increment/decrement hints

Reproduced `c++` as "expected an expression, found +" and `c--` as an
expression missing at EOF. Postfix and prefix `++` now explain `name += 1`;
a dangling postfix `--` explains `name -= 1`, highlighting the pair itself.
Three diagnostics cases have hand-read expectations. A runnable regression
also checks the suggested updates and preserves `c--1`, `--c`, spaced
subtraction of a negative value, and continuation onto the next line.

Judgement: do not reserve `--` lexically. It already denotes two ordinary
minus tokens in valid expressions. Diagnose attempted decrement only when
no operand follows; otherwise preserve subtraction/negation, including
existing operator line continuation. This is a hint change, not a grammar
restriction or a new decrement operator.

Full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests `-j1`,
native build `-j1`, doc examples (24 executed, 135 linked conformance files),
changed-file `zig fmt --check`, `git diff --check`, and Windows/macOS
cross-builds with prefixes outside `zig-out`. No suite failed.

## 2026-10-02 — Diagnostic polish item 3: conditional-value spelling

Reproduced C-style ternaries in a call, a declaration initializer, and a
nested function body. They previously suggested missing parentheses or a
statement terminator. Expression parsing now points at `?` and suggests
`if condition then value else other_value`; all three regressions report
one relevant correction without a closing-brace cascade. Read the expectation
and compared every message, source line, and span with the built CLI.

Judgement: recognize the mistake at the expression boundary, not in the
lexer. Optional type annotations and predicate names remain valid. A doubled
question mark is left alone for item 5's separate optional-default correction,
including the unspaced form whose first question mark belongs to a name token.

Full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests `-j1`,
native build `-j1`, doc examples (24 executed, 135 linked conformance files),
changed-file formatting, whitespace check, and Windows/macOS cross-builds
outside `zig-out`. No suite failed. Item 4 is next.

## 2026-10-02 — Diagnostic polish item 4: assignment in a condition

Reproduced the misleading block, parenthesis, `then`, and terminator errors
for `=` in conditions before changing code. Conditions now explain `==`
directly in ordinary and grouped `if`/`while` conditions, inline `if`,
statement/return guards, `assert`, and subjectless `case` arms. A hand-read
diagnostics case covers all seven paths; a runnable case checks correct
comparisons and ordinary assignments, including a captured assignment inside
an `any?` predicate. The built CLI matched both expectations after the gate.

Judgement: track condition context independently of control headers.
Parentheses must retain the comparison context, while lambda and statement
bodies must clear it. Diagnose the equal sign and consume its right-hand
expression for recovery, so the existing block/delimiter parser stays aligned;
the parse diagnostic prevents the invalid program from checking or executing.
Subjectless `when` and `assert` are conditions too, so use the same helper
rather than leave those with misleading delimiter errors.

Full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests `-j1`,
native build `-j1`, doc examples (24 executed, 135 linked conformance files),
changed-file formatting, whitespace check, and Windows/macOS cross-builds
outside `zig-out`. No suite failed. Item 5 is next.

## 2026-10-02 — Diagnostic polish item 5: optional fallback hint

Reproduced `x ?? 0`, `x??0`, and a call followed by `??0`: all previously
suggested a missing closing parenthesis. Each now highlights both question
marks and suggests `.or(default)`, with `value.or(0)` as a concrete example.
The new diagnostics expectation was written and read by hand, then compared
with the built CLI. Existing optional/predicate cases passed unchanged,
including the separate "a type cannot be optional twice" annotation error.

Judgement: handle both token shapes at the expression boundary rather than
change identifier lexing. In `x??0`, the first question mark belongs to the
identifier token; in spaced expressions and after calls both are standalone
tokens. This keeps predicate names and optional annotations untouched.

Full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests `-j1`,
native build `-j1`, doc examples (24 executed, 135 linked conformance files),
changed-file formatting, whitespace check, and Windows/macOS cross-builds
outside `zig-out`. The user's connection interruptions did not require a
restart: the existing build processes completed successfully. No suite failed.
Item 6 is next, followed by the group A push and CI check before review.

## 2026-10-02 — Diagnostic polish item 6: one-line lambda loop exits

Reproduced the parse errors and stray-closing-brace cascades from one-line
`break`/`continue` lambdas, including guarded exits within an outer loop.
The parser now treats those keyword-led bodies as ordinary block statements;
the existing checker explains that a function cannot exit its caller's loop.
No checker or diagnostic wording change was necessary. The four-error
conformance expectation was written/read by hand and matched the built CLI.
A parser unit test verifies all four forms parse cleanly before checking.

Judgement: reuse `parseStatement` and `finishLambdaBlock` only for the two
requested loop-exit keywords. Do not broaden every one-line lambda statement
form, add caller-loop control, or change lambda return semantics. Guarded
exits use the same condition parser introduced by item 4.

The full gate passed on pinned Zig 0.16.0: 548/548 tests in both Debug and
ReleaseSafe (`-j1`), native build, doc examples (24 executed, 135 linked
conformance files), `zig fmt --check src/*.zig tools/*.zig`, whitespace check,
and Windows/macOS cross-builds outside `zig-out`. All six group A items have
their own commits and completed gates. Push group A, check its seven CI jobs,
and stop for review before groups B and C; no merge or history rewrite.

## 2026-10-02 — Diagnostic polish group A: CI and review handoff

Pushed the six separate implementation commits through `2d92564` on
`codex/diagnostic-polish`, following the separately pushed policy commit
`3f7d694`. [Run 37020381290](https://github.com/amortimer20/emerald-lang/actions/runs/37020381290)
completed successfully at that exact code revision: all six platform/build
jobs and bounded execution fuzz passed. Group A is ready for review; groups
B and C have not started, and the branch is not merged.

The earlier [policy-only run](https://github.com/amortimer20/emerald-lang/actions/runs/37003741611)
failed Windows Debug because `emerald-repl.exe`'s test runner failed to respond
for `1m2.63ms`; its other six jobs passed. The log does not establish the
underlying cause, and the later green run is not evidence that the stall is
fixed. Recorded it as an active rough edge for separate investigation rather
than changing REPL code outside this group, rerunning the failed job, or
increasing its timeout. This follow-up records validation only; it changes
no source, examples, or expectations.

The documentation-only follow-up also passed the full local gate: Debug and
ReleaseSafe tests `-j1`, native build, documentation examples, formatting,
whitespace check, and both platform cross-builds. CI covers the unchanged
code at `2d92564`; Markdown-only pushes intentionally do not start a new run.

## 2026-10-02 — Diagnostic polish item 7: private module names

Reproduced a bare `_twice` in a different project file as `[E1001]` "not
defined", while `Shapes._twice` already recognized the privacy boundary. The
resolver now consults its declaration-owner facts when an otherwise undefined
bare private name has exactly one module-level owner, names that file, and
gives the established public-name correction. The existing project conformance
case now covers qualified and bare forms; its expectation was read by hand
against the built binary. The conformance harness strips the leading
`conformance/` prefix from source paths, so its golden fixture uses that
normalized path even though a direct CLI invocation prints the full path.

Judgement: only name a file when the private spelling has one owner. Files may
legitimately reuse private names; picking one declaration in that case would
turn an honest unknown-name diagnostic into a false correction. This is a
resolver-only improvement with no visibility or namespace semantic change.

## 2026-10-02 — Diagnostic polish item 8: omitted trait adoption

Reproduced a concrete `Square` with the complete public `Shape` contract being
assigned to `Shape`: it previously received only the generic declaration type
mismatch. The checker now recognizes this narrow nominal-conformance near miss
for concrete structs and classes, says that the type does not adopt the trait,
and points to `with Shape` on the type declaration. The conformance case covers
both a struct and a class, plus a `Triangle` that lacks the required member and
therefore deliberately retains the ordinary mismatch.

Judgement: inspect required public trait members with the same signatures,
property mutability, `Self` substitution, and inherited-member lookup already
used for declared adoptions. This diagnostic does not make structural typing a
language feature: absent `with`, the value remains unassignable. Traits with no
requirements, private members, traits themselves, enums, and incomplete or
wrong-shaped implementations retain the existing diagnostic, because suggesting
adoption there would hide the real missing member or imply a vacuous contract.

The focused CLI reproduction and Debug suite passed before the full gate. The
full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests with `-j1`,
native build, documentation examples (24 executed, 135 linked conformance
files), `zig fmt --check src/Checker.zig`, whitespace check, and Windows
x86_64/macOS aarch64 cross-builds with output outside `zig-out`.

## 2026-10-02 — Diagnostic polish item 9: bare nested type names

Reproduced `const size: Size`-style annotations inside an outer type: despite a
declared `Pizza.Size`, the checker said only that `Size` was not a type. It now
finds a direct nested type of the innermost containing declaration and suggests
the required qualified spelling, `Pizza.Size`. The focused diagnostics case was
written and read by hand against the built binary.

Judgement: use existing declaration spans and nested-type keys in the checker,
without changing resolution. The hint is offered only for an unqualified name
inside a type whose direct nested type has that name; unrelated unknown types
and already-qualified paths retain their established diagnostics. Choosing the
innermost containing type also extends naturally to nested declarations without
guessing across unrelated outer scopes.

The focused CLI reproduction and Debug suite passed before the full gate. The
full gate passed on pinned Zig 0.16.0: Debug and ReleaseSafe tests with `-j1`,
native build, documentation examples (24 executed, 135 linked conformance
files), `zig fmt --check src/Checker.zig`, whitespace check, and Windows
x86_64/macOS aarch64 cross-builds with output outside `zig-out`.

## 2026-10-02 — Diagnostic polish group B: CI and review handoff

Pushed Group B through `1809db4` on `codex/diagnostic-polish`. [Run
37037868996](https://github.com/amortimer20/emerald-lang/actions/runs/37037868996)
passed all six platform Debug/ReleaseSafe jobs and the bounded execution fuzz
job. Group B is ready for review; group C has not started, and the branch has
not been merged or rebased.
