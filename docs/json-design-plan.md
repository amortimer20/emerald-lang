# JSON: design and implementation plan

Status: proposed, 2026-09-26, awaiting the user's decisions below. Rewrite-context 15.7 lists
JSON as the next standard-library item. This plan proposes the API, how a statically typed
language holds a document of unknown shape, errors, and the order of work. The decisions are
recommendations; decision 3 changes how the checker types two calls and needs the user's
explicit go-ahead. At the start of each slice, reread `git status`, the recent `git log`, and
docs/handoff.md.

## What beginner programs need

The API is judged by these programs. Each should read naturally, and a mistake in the data
should produce a message that says where in the document it is.

```emerald
# Save a game's high scores, and load them next time.
struct Score {
    const name: String
    const points: Int
}

const scores = [Score("Ada", 120), Score("Grace", 95)]
File.write("scores.json", Json.encode(scores, pretty: true))
const loaded = Json.decode(File.read("scores.json"), as: List[Score])
print(loaded[0].name)                                   # Ada

# Read settings someone edited by hand, with defaults for what is missing.
const settings = Json.parse(File.read("settings.json"))
const volume = settings.get_maybe("volume")?.int_maybe().or(5)
const name = settings.get("player").string()            # a JsonError says where, if not text

# Walk a document whose shape is only partly known, such as an API response.
const weather = Json.parse(response)
print(weather.get("current").get("temperature").float())
for day in weather.get("daily").list() {
    print(day.get("date").string(), day.get("high").float())
}

# Build a document without declaring a struct for it.
const entry = Json.from_object(["name": Json.from_string("Ada"), "tags": Json.from_list([Json.from_string("new")])])
print(entry)                                            # {"name":"Ada","tags":["new"]}
```

`scores.json` then holds:

```json
[
  {
    "name": "Ada",
    "points": 120
  },
  {
    "name": "Grace",
    "points": 95
  }
]
```

## Principles

1. **Two ways in, for two situations.** When the program knows the document's shape, it says
   so with its own types, and the document is checked against them in one step
   (`Json.decode(text, as: Save)`). When it does not, as with an API response or a file
   someone else wrote, it walks a `Json` value, asking for each part's kind as it goes. Swift
   (`Codable` and `JSONSerialization`), Go (structs and `map[string]any`), and Rust (serde's
   derive and `serde_json::Value`) all offer the same two, for the same reason.
2. **Errors say where.** Bad JSON text reports its line and column and what was expected
   there. A value of the wrong kind reports its path in the document: `at players[2].score:
   expected a whole number, found the text "12"`. JSON is often edited by hand, and the path
   is what someone needs to find the mistake.
3. **Strict JSON, as RFC 8259 defines it.** No comments, trailing commas, single quotes,
   unquoted keys, `NaN`, or `Infinity`, since other programs will reject a file that has
   them. Each of these common mistakes gets its own message rather than a generic
   "unexpected character".
4. **Nothing surprising on the way back out.** Keys keep their order (dictionaries keep
   insertion order, struct fields their declaration order), a `Float` stays a `Float`
   (`2.0`, not `2`), and text is written as UTF-8, escaping only what JSON requires.
5. **The existing vocabulary.** The strict and `_maybe` pairs from 9.4 (`to_int` and
   `to_int_maybe`), and the `group` and `group_maybe` pair `Regex.Match` already follows.

## Verified constraints (checked against source, 2026-09-26)

- **Dictionaries keep insertion order,** in display, `keys()`, and iteration, so an object's
  keys can round-trip in order.
- **A struct can hold a `List` or `Dict` of itself,** and compares structurally, so a `Json`
  tree can be an ordinary prelude struct. Such a struct is not a dictionary key (8.3); nor,
  then, is a `Json` value.
- **No general overloading (7.3), no custom indexing (11.5), and no user generics (11.3).** So
  `doc["name"]` is not available for a user-level type, and navigation is by method:
  `get(key)` and `at(index)`. It also means no ordinary function signature can accept "any
  value that can become JSON" or return "the type named here"; see decision 3.
- **`?.` reaches a struct's fields and methods,** not a built-in type's, so
  `settings.get_maybe("volume")?.int_maybe()` works because `Json` is a struct. `x?.count` on
  an optional `Dict` does not.
- **The checker already types one call specially:** `print` and `write` accept any value,
  which no written signature can express. That special handling is the precedent for
  decision 3. The checker threads an expected type into literals, lambdas, and `case` and
  `if` expressions (`typeOfExpected`), but not into calls.
- **Empty dictionaries are written `[]`,** with the expected type deciding (8.2); `[:]` is
  only how one displays.
- **`null` can be an enum value's name,** so `Json.Kind.null` reads as JSON does.
- **A type-level function and a value's method cannot share a name:** with both
  `func J.string(...)` and `func string()`, `J.string(...)` is refused as reaching the
  value's method.
- **Numbers.** `Int` is 64-bit. `Float` displays as the shortest text that reads back as the
  same value, with `.0` on whole values and `-0.0` kept (9.4), which is what writing JSON
  needs.
- **Text is always valid UTF-8** in Emerald, so a JSON `\u` escape that names an unpaired
  surrogate must be refused; it has no Emerald string to become.
- **Zig's `std.json`** has a scanner and a writer, but its errors carry no messages a
  beginner could use, and its number handling differs from 9.4's. The parser here is small
  and Emerald's own (see "Implementation approach"). `std.json`'s JSONTestSuite cases are a
  useful check.

## Proposed API

All in the `Emerald` namespace.

```emerald
# Reading
Json.parse(text: String): Json                  # raises JsonError at a line and column
Json.parse_maybe(text: String): Json?
Json.decode(text: String, as: Type): Type       # decision 3

# Writing
Json.encode(value, pretty: Bool = false): String   # value: Json, or any encodable value (decision 3)

# The Json value
json.kind: Json.Kind                            # null, bool, number, string, list, object
json.null?(): Bool
json.get(key: String): Json                     # raises unless an object with that key
json.get_maybe(key: String): Json?              # nothing when not an object, or no such key
json.at(index: Int): Json                       # raises unless a list with that index
json.at_maybe(index: Int): Json?
json.keys(): List[String]                       # an object's keys, in order
json.count: Int                                 # a list's items or an object's entries
json.string(): String         json.string_maybe(): String?
json.int(): Int               json.int_maybe(): Int?
json.float(): Float           json.float_maybe(): Float?
json.bool(): Bool             json.bool_maybe(): Bool?
json.list(): List[Json]       json.list_maybe(): List[Json]?
json.object(): Dict[String, Json]   json.object_maybe(): Dict[String, Json]?

# Building
Json.null
Json.from_string(text: String): Json
Json.from_int(value: Int): Json
Json.from_float(value: Float): Json
Json.from_bool(value: Bool): Json
Json.from_list(items: List[Json]): Json
Json.from_object(entries: Dict[String, Json]): Json
```

- **Builders are `from_` functions** because a type-level function cannot share a name with
  a value's method: `Json.string(...)` would clash with `json.string()`. Reading is far more
  common than building, so the short names go to reading, and with decision 3 (a) most
  programs build JSON from their own structs instead.

- **`int()` accepts any number with no fractional part that fits in `Int`,** so `3`, `3.0`,
  and `3e2` all read as whole numbers: JSON has one number type, and the program that wrote
  the file may not have distinguished. `float()` accepts every number. A number too large
  for `Int` is kept as a `Float`, and `int()` then refuses it by name.
- **A `Json` value prints as compact JSON text** (it adopts `Textual`). Two are equal when they
  are the same JSON; numbers compare by value, so `1` equals `1.0`.
- **Paths travel with the value.** `get` and `at` give the child its path (`players[2]
  .score`), so a later `int()` can say where it failed. The path is not part of equality or
  display.
- **Duplicate keys are refused** when parsing, at the second one's line and column. RFC 8259
  says keys should be unique, and in a file edited by hand a duplicate is almost always a
  mistake that silently discards data if the last one wins, as JavaScript, Python, and Go
  let it.
- **Nesting is limited** to 512 levels, so a malicious or broken document cannot exhaust the
  stack. The limit is in the message when it is reached.
- **No `Json.read_file`.** `Json.parse(File.read(path))` is two familiar pieces, and a
  `FileError` and a `JsonError` stay distinct. The docs will show the pattern.

## Decisions

1. **Name: `Json`,** not `JSON`. Emerald's types are written like words (`Regex`), and the
   standard library's later `Http` and `Csv` should match. Alternative: `JSON`, which Swift
   and JavaScript use, at the cost of a second capitalization rule.
2. **Verbs: `parse` for a `Json` value, `decode` and `encode` for the program's own types.**
   `parse` already means "read text into a value" in Emerald (`Date.parse`). `decode` and
   `encode` are Go's and Swift's words for the typed direction, and naming it differently
   tells the reader that a type is involved. Alternative: `Json.parse(text, as: Save)`,
   one verb with two meanings.
3. **Typed encoding and decoding, which needs the checker's help (the main decision).** No
   written signature can say "any value that can become JSON" or "a value of the type named
   here". Three options:
   - **(a) Recommended.** Type `Json.encode` and `Json.decode` specially, as `print` already
     is. `encode` accepts any encodable type, reporting at check time what is not (a `Set`,
     a class, a function, or a struct with a field that is not). `decode` takes a type as its
     `as:` argument, written as in an annotation (`as: List[Score]`), and its result has that
     type. The rule for what is encodable is small and written down: `String`, `Int`,
     `Float`, `Bool`, optionals (as `null`), `List`, `Dict[String, _]`, enums (by value
     name), `Json`, `Date`, `Time`, `DateTime`, `Instant` (as their ISO 8601 text), and
     structs whose fields all are. A struct decodes through its generated constructor, so a
     struct with a custom constructor, or a private field without a default, cannot be
     decoded, and the checker says so.
   - **(b)** A trait, `JsonEncodable`, with `to_json(): Json` and a type-level `from_json`,
     written by hand for each struct. No special checking, but every struct needs two
     methods that repeat its fields, which is the tedium beginners should not face.
   - **(c)** Only the `Json` value for now, deferring typed conversion to user generics
     (11.3). Nothing special in the checker, but saving and loading a program's own data,
     the most common beginner use, stays verbose: every field is read and converted by
     hand.

   Option (a) adds a type written as an argument, which Emerald does not have elsewhere. It is
   confined to `as:` on this one call, where the reading ("decode this text as a list of
   scores") is plain, and it can become an ordinary generic parameter if 11.3 ever brings
   generics.
4. **Missing and extra fields when decoding.** A missing field with a default, or of an
   optional type, takes the default or `nothing`; a missing required field raises with the
   path. An extra field in the document is ignored: files gain fields over time, and an old
   program should still read them. Alternative: refuse extra fields, which catches typos in
   hand-written files but breaks on every added field.

## Errors

- **`JsonError`** extends `RuntimeError`.
- **Bad text:** `line 3, column 18: expected "," or "}" after this value`. Specific messages
  for common mistakes: `JSON does not allow a comma before "}"`, `JSON strings use double
  quotes, not single quotes`, `JSON object keys need double quotes: write "name"`, `JSON has
  no comments`, `NaN is not a JSON number`, `this text ends inside a string that started at
  line 2, column 5`, and `a "\u" escape here names half of a surrogate pair without the other
  half`.
- **Wrong kind:** `at players[2].score: expected a whole number, found the text "12"`. The
  root is written `the document`: `the document is a list, not an object, so it has no key
  "name"`.
- **Missing key or index:** `at settings: there is no key "volume"; its keys are "name" and
  "theme"`, listing up to ten keys. `at scores: there is no item 5; the list has 3 items`.
- **Encoding:** a non-finite `Float` raises at run time (`NaN cannot be written as JSON`),
  since JSON has no way to write it. With decision 3 (a), a type that cannot be encoded is a
  check-time diagnostic naming the field that is not encodable.
- **Decoding:** wrong-kind and missing-field errors carry the path, as above, and a value
  outside a type's range (a `Date` string that is not a date, an enum name that is not one of
  its values) names the path and the reason.

## Implementation approach

- **The parser and writer are native Zig** (`src/Json.zig`): a single pass over the text,
  tracking line and column, iterative with an explicit stack so depth cannot overflow the Zig
  stack, and producing Emerald values directly, as `Regex`'s `_find` builds `Regex.Match`.
  Writing is a single pass over the value. Both are independent of the interpreter, like
  `Regex.zig`, so a future compiled backend reuses them.
- **The `Json` value is a prelude struct** with private fields: its kind, one field per kind's
  payload (a `Bool`, a `Float` and an `Int`, a `String`, a `List[Json]`, a `Dict[String,
  Json]`), and its path. Navigation and conversion are Emerald methods in the prelude over
  those fields; only parsing and writing are native.
- **Typed conversion (decision 3 (a))** is two checker special cases, in the same place as the
  Regex literal check, plus a native encoder and decoder that follow the static type the
  checker records at the call.
- **Startup cost.** The prelude grows again. Measure `print(1)` before and after, as the date
  and regex slices did. The planned startup work (check only what a program uses) follows
  this milestone.

## Slices

Each slice is runnable and committed on its own, with AGENTS.md's validation and
rewrite-context text written in the same change.

1. **The parser and writer, without Emerald.** `src/Json.zig`: parsing with line and column
   errors for every mistake above, the depth limit, numbers per this plan, escapes and
   surrogate pairs, and compact and pretty writing. Zig unit tests, JSONTestSuite's
   accept/reject cases (fetched from its GitHub mirror, as the Unicode data was), and a local
   differential check against Python's `json` on generated documents.
2. **The `Json` value.** `Json.parse`, `parse_maybe`, `kind`, navigation, conversions, paths
   in errors, display, and equality; `JsonError`; conformance for each kind, every error
   message, Unicode text, and large and deep documents.
3. **Building and writing.** `Json.null` and the `from_string`, `from_int`, `from_float`,
   `from_bool`, `from_list`, and `from_object` builders, and `Json.encode` for `Json` values, compact and pretty; round-trip
   conformance.
4. **Encoding the program's own values** (decision 3). The checker accepts encodable types and
   reports others at the field that is not; the native encoder; conformance and diagnostics
   cases.
5. **Decoding into the program's own types.** `Json.decode(text, as: Type)`: the checker
   types the result, the decoder builds values through generated constructors, with missing
   and extra fields per decision 4 and path errors; conformance and diagnostics cases.
6. **Documentation and integration.** `docs/library/json.md`, an inventory row,
   `examples/json.em` with the programs above, a new rewrite-context section and decision
   rows in 22, 15.7 updated, and a fuzz template.

If decision 3 goes to (c), slices 4 and 5 are dropped, and `Json.encode` takes only a `Json`.

## Out of scope for this milestone

Streaming very large documents, JSON Lines, JSON5 and comments, JSON Schema, JSONPath queries,
choosing field names that differ from the struct's (renaming by annotation), encoding
classes, and preserving numbers beyond `Float`'s precision exactly. Each can be revisited
with a real program that needs it (24).

## Risks

- **Decision 3 (a) is new checker surface.** It is confined to two calls, but the rule for
  what is encodable must be explained in one short paragraph, or it is too complicated. If it
  grows exceptions, fall back to (c) and revisit with generics.
- **Many small objects.** A parsed document becomes a tree of structs, lists, and
  dictionaries, and `Regex`'s slice 3 showed building values costs more than the native work.
  Measure a 1 MB document in slice 2; if it is slow, keep a parsed document native and build
  children only when navigated to.
- **Differences from other parsers** (refused duplicates, ignored extra fields, `int()`
  accepting `3.0`) are listed on the library page with their reasons.
