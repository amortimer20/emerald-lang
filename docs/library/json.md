# Json

`Json` reads and writes strict JSON: a document a program owns, such as saved
settings, and a document whose shape is only known after reading it, such as an API response.
Run [`examples/json.em`](../../examples/json.em) for both ways of working, and see
[`conformance/run/json-decoding.em`](../../conformance/run/json-decoding.em) and
[`conformance/run/json-building.em`](../../conformance/run/json-building.em) for focused,
runnable coverage.

```emerald
struct Score {
    const name: String
    const points: Int
}

const scores = [Score("Ada", 120), Score("Grace", 95)]
const saved = Json.encode(scores, pretty: true)
const loaded = Json.decode(saved, as: List[Score])
print(loaded[0].name)    # Ada
```

JSON is strict RFC 8259 JSON. It has no comments, trailing commas, single-quoted text,
unquoted object keys, `NaN`, or `Infinity`.

## Json.parse(text: String) -> Json

Reads a document whose shape is not known yet. The result has one of the six values in
`Json.Kind`: `null`, `bool`, `number`, `string`, `list`, or `object`.

**Raises** `JsonError` if `text` is not JSON. The message gives the line and column of the
first problem, such as a trailing comma or an unclosed string. A duplicate key is also an
error, including keys that differ only by Unicode normalization.

## Json.parse_maybe(text: String) -> Json?

As `parse`, but returns `nothing` for invalid JSON instead of raising.

## Json.decode(text: String, as: Type) -> Type

Reads JSON into a type the program already knows. `as:` is a type, not a value, and the result
has that same type:

```emerald
struct Settings {
    const name: String
    const volume: Int = 5
    const note: String?
}

const settings = Json.decode("{\"name\": \"Emerald\"}", as: Settings)
print(settings.volume, settings.note)    # 5 nothing
```

The target may be `String`, `Int`, `Float`, `Bool`, an optional, `List`, `Dict[String, V]`,
an enum, `Json`, `Date`, `Time`, `DateTime`, `Instant`, or a plain struct made from those
types, including a struct that holds itself, such as a tree. A struct must use its generated
constructor. A field the document gives is read from it; a missing field takes its default, or
`nothing` when it is optional and has none; extra object keys are ignored. A private field is
never read from JSON: it must have a default, and always takes it. A target outside that set
is a checking error before the program runs.

`Json.decode` must be called by that name (or `Emerald.Json.decode`): that is how `as:` is
recognized as a type. Neither `Json.decode` nor `Json.encode` can be kept as a value.

**Raises** `JsonError` for invalid text, a missing required field, or a JSON value of the
wrong kind. Its message identifies the value's path, such as `players[2].score` or
`["first name"]`.

## Json.encode(value, pretty: Bool = false) -> String

Writes JSON. With `pretty: false` (the default), the result is compact; `pretty: true` uses
two spaces per indentation level.

`value` may be a `Json`, `String`, `Int`, `Float`, `Bool`, optional, `List`,
`Dict[String, V]`, enum, `Date`, `Time`, `DateTime`, `Instant`, or a plain struct whose public
fields are all among those types. Private fields are never written. Object keys follow
dictionary insertion order and struct fields follow declaration order. Enums write their value names, and absent optionals write `null`.

**Raises** `JsonError` when a `Float` value is `NaN` or infinite. Other types JSON cannot
represent — such as `Set`, `Bytes`, a function, a class, or a bad struct field — are checking
errors.

## Json values

`Json.null -> Json` is the JSON null value.

`Json.from_string(text: String) -> Json`, `Json.from_int(value: Int) -> Json`,
`Json.from_float(value: Float) -> Json`, and `Json.from_bool(value: Bool) -> Json` build
their matching scalar kind. `Json.from_list(items: List[Json]) -> Json` and
`Json.from_object(entries: Dict[String, Json]) -> Json` build containers. Lists and objects
take values that are already `Json`, which keeps nesting explicit:

```emerald
const entry = Json.from_object([
    "name": Json.from_string("Ada"),
    "tags": Json.from_list([Json.from_string("new")]),
])
print(entry)    # {"name":"Ada","tags":["new"]}
```

`from_float` raises `JsonError` for `NaN` and infinity. Every `Json` prints as compact JSON,
and two values are equal when they represent the same JSON: object key order and a number's
whole-versus-decimal spelling do not affect equality.

### kind -> Json.Kind, null?() -> Bool, count -> Int, keys() -> List[String]

`kind` is the value's `Json.Kind`. `null?()` says whether it is JSON null. `count` is the
number of items in a list or entries in an object, and `keys()` returns an object's keys in
document order.

**Raises** `JsonError` when `count` or `keys()` is reached on the wrong kind.

### get(key: String) -> Json, get_maybe(key: String) -> Json?

`get` reads an object entry. `get_maybe` returns `nothing` when the receiver is not an object,
or has no such key.

### at(index: Int) -> Json, at_maybe(index: Int) -> Json?

`at` reads a list item. `at_maybe` returns `nothing` when the receiver is not a list, or has
no item at that index. Both strict methods return another `Json`, so a program can keep
navigating:

```emerald
const document = Json.parse("{\"player\": {\"name\": \"Ada\"}}")
print(document.get("player").get("name").string())    # Ada
```

`get`, `at`, `count`, and conversions keep track of where a child came from, so a later error
names its document path.

**Raises** `JsonError` when strict `get` or `at` cannot find its requested entry or is called
on the wrong kind.

### Conversions

`string() -> String`, `int() -> Int`, `float() -> Float`, `bool() -> Bool`,
`list() -> List[Json]`, and `object() -> Dict[String, Json]` are strict conversions.
`string_maybe() -> String?`, `int_maybe() -> Int?`, `float_maybe() -> Float?`,
`bool_maybe() -> Bool?`, `list_maybe() -> List[Json]?`, and
`object_maybe() -> Dict[String, Json]?` return `nothing` instead of raising.

`int()` accepts a JSON number only when it has no fractional part and fits in `Int`, so `3`,
`3.0`, and `3e0` are all valid. `float()` accepts any JSON number. `list()` and `object()`
return `List[Json]` and `Dict[String, Json]`; their children retain useful paths for later
navigation or conversion.

**Raises** `JsonError` for the strict form when the kind does not match (or when `int()` would
not fit in `Int`).

## JsonError

`JsonError` extends `RuntimeError`. Catch it when a program can recover from bad input while
letting unrelated runtime failures continue upward. See
[`conformance/runtime-errors/json-decode-wrong-kind.em`](../../conformance/runtime-errors/json-decode-wrong-kind.em)
for a path-rich conversion error.
