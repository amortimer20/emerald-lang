# String

`String` is immutable and Unicode-aware (9.1). No method below changes the receiver; every
one returns a new value. Indexing and every method here counts extended grapheme clusters —
a displayed character, such as an accented letter or an emoji built from several code
points — never a raw byte or code point, so a character is never split. Locating a grapheme
is linear time, which is the honest cost of that guarantee; `code_points()` and `bytes()`
below are the advanced escape hatch when a program specifically needs code points or raw
UTF-8 bytes instead.

`letter?`, `digit?`, `words`, `title_case`, and case-insensitive comparison remain deferred.
`+` joins two strings and `+=` appends; it is the one operator strings
have, and it does not convert a non-`String` operand (`"Score: " + 10` is rejected in favor
of interpolation or `to_string()`). Equality (`==`) and ordering compare Unicode-normalized
text, not raw bytes, so two byte-different but canonically equivalent strings are equal; a
`String` itself always keeps the exact bytes it was built from.

Run [`conformance/run/string-methods.em`](../../conformance/run/string-methods.em) for the
value cases below,
[`conformance/run/range-slicing.em`](../../conformance/run/range-slicing.em) for range
slicing,
[`conformance/diagnostics/string-editing.em`](../../conformance/diagnostics/string-editing.em)
for argument-type and arity mistakes, and
[`conformance/runtime-errors/string-padding.em`](../../conformance/runtime-errors/string-padding.em)
for one **Raises** case in detail.

## Size and conversion

## count -> Int

A read-only property (no parentheses): the number of graphemes.

## empty?() -> Bool

## blank?() -> Bool

`empty?()` is true only for `""`. `blank?()` is also true for a string of nothing but
Unicode whitespace.

## chars() -> List[String]

## code_points() -> List[Int]

## bytes() -> List[Int]

`chars()` is the grapheme-aware, beginner-facing way to get each character as its own
one-grapheme `String`. `code_points()` and `bytes()` are advanced, exact-representation
views of the same text: Unicode scalar values (so a decomposed character has more than one
entry) and raw UTF-8 octets, respectively — neither is "characters," and beginner code
should reach for `chars()` instead.

## Casing

## upper() -> String

## lower() -> String

## capitalize() -> String

`capitalize()` uppercases only the first grapheme (Unicode's locale-independent mapping) and
leaves the rest untouched; `""` is returned unchanged. It does not lowercase the remainder —
a method that did would need a name that says so.

## Whitespace

## trim() -> String

## trim_start() -> String

## trim_end() -> String

All three remove whole graphemes of Unicode whitespace, never a partial character.

## Search

These methods take their argument literally: `"a.b".contains?(".")` looks for a dot. To
search by pattern, such as "any run of digits", use a [`Regex`](regex.md).

## contains?(text: String) -> Bool

## starts_with?(text: String) -> Bool

## ends_with?(text: String) -> Bool

## index_of(text: String) -> Int?

All four match only where both ends of the match fall on a grapheme boundary, and compare
canonically, the same rule `==` uses — so `"café".contains?("e")` is `false` when the `é` is
one character, since the plain `e` inside it is not a character of its own. `index_of`
returns the optional first match position rather than `-1`, per the optionals rule in 4.5.

## Editing

## text[start..<end] -> String

## text[start..end] -> String

Both forms return an independent substring measured in grapheme clusters. `..<` excludes its
end and permits `count`; `..` includes its end and therefore must name an existing character.
Either endpoint may be omitted only inside the brackets (`text[..<3]`, `text[2..<]`). A start
after the end and every out-of-range endpoint raise rather than being clamped.

## replace(old: String, new: String) -> String

Replaces every occurrence of `old`.

**Raises** when `old` is `""` (there is no matched character to replace).

## insert_at(index: Int, text: String) -> String

Inserts `text` before the grapheme at `index`; `0` is the start and `count` is a valid index
that appends.

**Raises** for a negative index or one past `count`.

## substring(start: Int) -> String

## substring(start: Int, count: Int) -> String

The one-argument form continues to the end of the string; the two-argument form takes
exactly `count` graphemes. A `start` equal to the string's length is valid and produces `""`;
`count` of `0` is valid.

**Raises** for a negative `start` or `count`, or a requested span that runs past the end —
never silently clamped.

## reverse() -> String

## repeat(times: Int) -> String

`repeat` concatenates the receiver with itself `times` times.

## remove_prefix(prefix: String) -> String

## remove_suffix(suffix: String) -> String

Each returns the receiver unchanged when it does not start/end with the argument
(canonically matched); a successful removal preserves the remaining original bytes exactly.

## collapse_repeats() -> String

Replaces every run of adjacent, canonically equal graphemes with its first one:
`"baallooon".collapse_repeats()` is `"balon"`.

## Layout

## pad_start(width: Int) -> String

## pad_start(width: Int, fill: String) -> String

## pad_end(width: Int) -> String

## pad_end(width: Int, fill: String) -> String

## pad_center(width: Int) -> String

## pad_center(width: Int, fill: String) -> String

`width` is measured in graphemes; `fill` defaults to `" "` and must be exactly one grapheme.
A string already at least `width` long is returned unchanged. `pad_center` places an odd
leftover fill character at the end: `"hi".pad_center(5, "-")` is `"-hi--"`.

**Raises** for a negative `width`, or a `fill` that is empty or more than one grapheme.

## Decomposition

## split(separator: String) -> List[String]

## lines() -> List[String]

`lines()` omits line endings: a line ends at `\n`, a `\r` immediately before one belongs to
the ending, and a trailing line ending does not start an empty final line.

**Raises**, for `split`, when `separator` is `""` (use `chars()` to split into characters).

## Structural helper

## partition(separator: String) -> (String, String, String)

Splits into the text before the first match, the matching text, and the text after it. With
no match, the result is `(text, "", "")`.

**Raises** when `separator` is `""`.

## Parsing

## to_int() -> Int

## to_int_or(fallback: Int) -> Int

## to_int_maybe() -> Int?

## to_float() -> Float

## to_float_or(fallback: Float) -> Float

## to_float_maybe() -> Float?

Strict parsing (9.4): `to_int` accepts an optional sign and decimal digits only; `to_float`
additionally accepts a fraction, an exponent, and the literal spellings `Infinity`,
`-Infinity`, and `NaN`, so every value `Float` display produces parses back. The three
suffixes are the same choice 4.4 offers every fallible conversion: raise on failure, supply a
fallback, or answer `nothing`.

**Raises**, for `to_int`/`to_float`, when the text does not parse.
