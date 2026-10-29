# Area 6: the standard library against reference implementations

Review plan section 4, area 6. Branch `claude/review-stdlib`, run on macOS (Darwin 27, arm64)
with the debug build from `zig build -j1` (Zig 0.17.0). References: Python 3.9.6
(`unicodedata` 13.0, `decimal`, `math`, `datetime`, `zoneinfo`, `json`, `csv`, `re`, `base64`,
`hashlib`, `hmac`).

**Result: 9 findings from about 89,900 differential cases.** One is a crash, seven are wrong
answers, and one is a documentation contradiction. Regex, Base64, SHA-256/HMAC, dates, times,
and zones came out clean.

## Method

Every family script under `docs/review/repro/stdlib/` generates inputs from a fixed seed. It
computes the reference answer in Python at the level the spec states (graphemes for `String`,
NFC for comparison, Emerald's own display rules for `Float`). Then it writes one Emerald
program with each case in its own `try`/`catch` and compares the printed results. `harness.py`
runs the cases in chunks of 1,500. A chunk that times out or crashes is split in half, again
and again, until the case responsible is isolated. So a hang would show up as `HANG` against
a single case, and a panic as `CRASH`.

Run a family from the worktree root:

```
python3 docs/review/repro/stdlib/strings.py
python3 docs/review/repro/stdlib/numeric.py
python3 docs/review/repro/stdlib/collections_.py
python3 docs/review/repro/stdlib/dates.py
python3 docs/review/repro/stdlib/formats.py [json|csv|regex|b64]
```

`FILTER=prefix,...` limits the run to cases whose labels start with a given prefix.

**On hangs.** No case hung. Early runs hit the 600 s subprocess timeout. The cause was CPU
contention from other review agents' benchmark runs on the same machine, which pushed wall
time to about ten times CPU time. Once the harness bisected each timed-out chunk, every case
completed (each 1,500-case chunk took about 0.1 s of CPU per hundred cases).

| Family | Cases | Raw mismatches | Findings |
| --- | ---: | ---: | --- |
| `String` (casing, trim, split, lines, words, replace, search, pad, substring, reverse, parsing, chars, code points, bytes, character tests, count) | 17,758 | 274 | 04, 09 |
| `Int`, `Float`, `Math` (arithmetic and overflow, `//`, `%`, `**`, rounding, `round_to`, `format`, bases, gcd/lcm/digits/factorial, `square_root`, trig, logs, `max`/`min`) | 38,373 | 731 | 02, 03, 05, 06 |
| `List`, `Dict`, `Set` (sort/sort_by stability, Floats with signed zero and infinities, Strings, unique, frequencies, group_by, chunks, windows, zip, pairs, take/drop, sum, average, min/max(_by), index_of, repeat, join, reduce, set algebra, merge, map_values, filter, remove) | 8,710 | 18 | 01 |
| `Date`, `Time`, `DateTime`, `Duration`, `Instant`, `TimeZone` (month-end and leap arithmetic, add/subtract, days/months/years_until, parse, display, wrap, duration_until, Duration display and arithmetic, Unix conversion, nine IANA zones, `to_instant` round trip, DST gap and fold) | 17,628 | 1 | none |
| JSON (parse/encode round trips, pretty form, escapes, Unicode, numbers, strict errors, nesting limit, duplicate keys) | 1,479 | 141 | none |
| CSV (format against reference minimal quoting, format/parse round trip, parsing Python-written CSV with `QUOTE_MINIMAL`/`QUOTE_ALL` and both line endings, edge texts, records) | 927 | 18 | 07, 08 |
| `Regex` (find_all spans, matches?, contains_match?, replace, replace_all, split, ignore_case, multiline, escape, grapheme and canonical rules, refused features, linear time) | 3,853 | 0 | none |
| Base64, hex, SHA-256, HMAC-SHA256 (0 to 300 bytes, keys of 0 to 200 bytes, URL-safe, padding, whitespace, invalid input, 1 MB digest) | 1,140 | 2 | none |

Every raw mismatch is accounted for below: it is either one of the findings, a documented
difference, or an error in my first reference that I corrected (for example, Python's `**`
raising `OverflowError` before deciding NaN, or a `TimeZone.fixed` case that `time-zone.md`
correctly says raises).

## Findings, ranked

The reproductions are `docs/review/repro/stdlib/NN-*.em`. Each prints Emerald's answer, and its
comments give the expected one.

### 01. `group_by` panics once any group reaches five items (crash)

`01-group-by-five-items.em`: `[1, 1, 1, 1, 1].group_by { x => x }`

- **Emerald:** `panic: reached unreachable code`, an assertion in `addOneAssumeCapacity`
  called from `callGroupBy` (`src/Interpreter.zig:8744`). The debug build aborts with
  exit code -6. A release build would write past the end of the group's buffer.
- **Expected:** `[1: [1, 1, 1, 1, 1]]`.
- **Source:** `docs/library/list.md`, group_by: "Groups by first-appearance key order, keeping
  each item's original order within its group." No limit on group size is stated.
- **Notes:** each group list is created with capacity 1 and then grown with
  `appendAssumeCapacity`. It works only while the allocator's rounding leaves room, which is
  up to four items. This is found by a program and is not listed as a source review. Any
  realistic `group_by` over more than a handful of items crashes.

### 02. `Float %` with a negative divisor takes the dividend's sign (wrong answer)

`02-float-modulo-negative-divisor.em`

- **Emerald:** `7.0 % -2.0` is `1.0`, `7.5 % -2.0` is `1.5`, `5.0 % -3.0` is `2.0`, and
  `0.5 % -2.5` is `0.5`. `(7.0 // -2.0) * -2.0 + 7.0 % -2.0` is `9.0`.
- **Expected:** `-1.0`, `-0.5`, `-1.0`, `-2.0`, and `7.0`. A negative dividend with a positive
  divisor is already right (`-7.0 % 2.0` is `1.0`). `Int %` passed all 1,600 sign
  combinations.
- **Source:** rewrite-context 5.3: "`%` uses the matching floor-division law
  `a == (a // b) * b + (a % b)`; for finite operands a nonzero remainder has the divisor's
  sign."
- **Scale:** 301 of 7,423 Float `%` cases, which is every case with a positive dividend and a
  negative divisor.

### 03. `Float //` floors the rounded quotient, which breaks the law with `%` (wrong answer)

`03-float-floor-division-law.em`

- **Emerald:** `0.5 // 0.1` is `5.0`, `0.5 % 0.1` is `0.09999999999999998`, so
  `(a // b) * b + a % b` is `0.6`. Other cases: `-0.5 // 1e-6` gives `-500000.0`, where Python
  gives `-500001.0`.
- **Expected:** `4.0`. The literal `0.1` is slightly more than one tenth, so the true quotient
  is just under 5. That makes the law hold (`4 * 0.1 + 0.0999… == 0.5`), as Python's `//`
  does.
- **Source:** 5.3: "`//` rounds toward negative infinity … `%` uses the matching floor-division
  law."
- **Notes:** `//` appears to compute `floor(a / b)` after `/` has already rounded, while `%`
  is computed exactly. These are 37 cases. Fixing 02 and 03 together, the way CPython's
  `float_divmod` does (`//` derived from `fmod`), restores the law.

### 04. `split` and `replace` return NFC text, not the receiver's bytes (wrong answer)

`04-split-replace-normalize.em`

- **Emerald:** `"cafe\u{301}".split(",")[0].code_points()` and
  `"cafe\u{301}".replace("x", "y").code_points()` are both `[99, 97, 102, 233]`. The same
  happens when a match is found (`"cafe\u{301} x".split("x")`). `trim`, `partition`,
  `remove_prefix`, `pad_*`, `collapse_repeats`, `substring`, and `chars` all keep the
  original bytes.
- **Expected:** `[99, 97, 102, 101, 769]`.
- **Source:** rewrite-context 9.2: "**Normalization happens at comparison, not at
  construction.** A `String` retains exactly the bytes it was built from … normalizing on
  construction, was rejected because it would silently rewrite user data passing through the
  standard library." Also: "a successful removal preserves the receiver's remaining original
  bytes" (for `remove_prefix`), and the same principle applies to every other method.
- **Scale:** 270 cases, which is every `split` and `replace` on a decomposed input. The
  pieces compare `==` correctly, so equality tests never catch it. Writing a file back
  through `split`/`join` changes its bytes.

### 05. `round_to` changes large values it should leave unchanged (wrong answer)

`05-round-to-large-magnitude.em`

| Expression | Emerald | Expected |
| --- | --- | --- |
| `2247410860550237.2.round_to(2)` | `2247410860550237.0` | `2247410860550237.2` |
| `3949998310996723.5.round_to(1)` | `3949998310996723.0` | `3949998310996723.5` |
| `1e300.round_to(5)` | `1.0000000000000002e+300` | `1e+300` |
| `1e300.round_to(-300)` | `1.0000000000000006e+300` | `1e+300` |
| `(-28609247935418.004).round_to(2)` | `-28609247935418.01` | `-28609247935418.0` |

- **Source:** rewrite-context 9.3: "`round_to` accepts every `Int` place count: precision
  beyond binary64's decimal range leaves a finite value unchanged on the fractional side."
  `float.md` says the same. A value with no fractional digits left at that magnitude must
  come back unchanged, and `1e300` rounded to -300 places is `1e300`.
- **Notes:** this looks like scaling by `10**places`, rounding, and dividing back, which loses
  bits once `x * 10**p` passes 2^53. The rule for this range is in the spec, so these are
  findings. The ordinary 2.675 cases are a separate question (see D1).

### 06. `Float **` and `Math.power` are inaccurate for large exponents (wrong answer)

`06-float-power-accuracy.em`

- **Emerald:** `1.1 ** 1000.0` is `2.469932918005993e+41`, and `Math.power(1.005, 123456.789)`
  is `2.6003345963808807e+267`.
- **Expected:** `2.4699329180060256e+41` and `2.600334596395491e+267`, as C's `pow` and Python
  give. The relative errors are about 1.3e-12 and 5.6e-12, roughly ten thousand ulps.
- **Source:** 9.3 and `math.md`: "`Math` follows ordinary IEEE `Float` results", and `**` has
  the same contract. A platform `pow` is accurate to within 1 ulp. This error looks like
  `exp(b * log(a))` evaluated in double precision.
- **Scale:** 39 power cases were outside the 1e-12 tolerance. Small exponents (`2.0 ** 0.5`,
  `10.0 ** 22`) are exact.

### 07. `Csv.format` loses a row that holds one empty field (wrong answer)

`07-csv-format-empty-row.em`

- **Emerald:** `Csv.format([[""]])` is `""`, and `Csv.parse` of that gives `[]`.
  `Csv.format([["a"], [""]])` is `"a\n"`, which parses to `[["a"]]`. A row is lost in each
  case (15 round-trip cases).
- **Expected:** `"\"\""` and `"a\n\"\""`, as Python's `csv.writer` writes them. Each parses
  back to the original rows.
- **Source:** `csv.md`, `Csv.format`: "A field is quoted only when needed to preserve its
  meaning." A lone empty field needs quoting to survive the trip.

### 08. A CSV separator matches inside a grapheme (wrong answer)

`08-csv-separator-splits-grapheme.em`

- **Emerald:** `Csv.parse("ae\u{301}b", separator: "e")` gives fields `[97]` and `[769, 98]`,
  so the combining accent starts a field on its own.
- **Expected:** `[["ae\u{301}b"]]`. The `e` inside `é` is not a character of its own, just as
  `String.split("e")` and `contains?("e")` treat it, and both passed.
- **Source:** 9.1 ("a displayed character … is not split accidentally"), 9.2's search rule,
  and 15.11 ("one grapheme as `separator:`").

### 09. The docs call `words`, `letter?`, and `digit?` deferred, but they ship (misleading doc)

`09-doc-says-deferred.em`

- **What the docs say:** `docs/library/string.md` opens with "`letter?`, `digit?`, `words`,
  `title_case`, and case-insensitive comparison remain deferred", then documents
  `letter?`/`digit?`/`words` below. Rewrite-context 9.2 says the same in its `code_points`
  paragraph ("`words`, `title_case`, case-insensitive Unicode comparison, `letter?`, and
  `digit?` remain deferred"), while its vocabulary list and its character-test paragraph
  (dated 2026-10-28) include them.
- **Emerald:** all three run, and they pass every differential case.
- **Expected:** the "deferred" sentences name only `title_case` and case-insensitive
  comparison.

## Documented differences (not findings)

These disagree with Python because the spec or reference docs choose otherwise, or Python's
semantics differ in ways Emerald does not promise to follow.

**D1. Decimal-display rounding in `round_to` and `format` (needs a decision).** Emerald rounds
the shortest decimal display, not the exact binary value:

- `2.675.round_to(2)` is `2.68`, `1.005.format(decimal_places: 2)` is `"1.01"`, and
  `1.45.round_to(1)` is `1.5`. Python's exact answers are 2.67, 1.00, and 1.4, because those
  doubles lie just below the halfway point.
- `1e300.format(decimal_places: 0)` writes `1` followed by 300 zeros, where the exact binary
  expansion is `1000000000000000052504…`. Likewise `0.1.format(decimal_places: 20)` is
  `0.10000000000000000000`.
- `round_to` and `format` agree with each other, and this is arguably the beginner-friendly
  choice. But the spec says only "halfway values round away from zero" without saying
  halfway in which representation, so I recommend stating it (210 cases).

**D2. `Int / Int`.** Emerald widens both operands to `Float` and then divides, so above 2^53
it can be one ulp from Python's exactly rounded `int / int` (85 cases). This follows 4.4's
widening.

**D3. `Float %` and `//` edge cases** that 5.3 does not specify:

- the sign of a zero remainder: `0.0 % -0.5` is `0.0` and `-0.0 % 0.5` is `-0.0`, where
  Python gives `-0.0` and `0.0`;
- `Float.infinity // 1.0` is `Infinity` (Python: NaN);
- `-1.0 // Float.infinity` is `-0.0` (Python: `-1.0`).

5.3 makes the remainder NaN for an infinite operand, so the law does not constrain `//` there.

**D4. `Math.log(0, b)`** gives `±Infinity`, and domain errors give `NaN`, as IEEE and
`math.md` say. Python raises.

**D5. Parsing (9.2, 9.4).**

- `to_float` rejects `inf`, `nan`, `+Infinity`, `-NaN`, `1_0`, `.5`, and `5.`, and raises for
  `1e400` ("outside the range of Float"). Python accepts all of these.
- `to_int` rejects underscores and non-ASCII digits (`"\u{663}"`, `"\u{FF11}"`). Python
  accepts both.
- Surrounding whitespace is Unicode `White_Space`, so U+00A0 and U+3000 are accepted.

**D6. Whitespace and lines.**

- `trim`, `words`, and `whitespace?` use `White_Space`, which excludes U+001C–U+001F.
  Python's `isspace` includes them.
- `lines()` ends lines only at `\n` and `\r\n`. Python's `splitlines` also ends them at `\r`,
  `\v`, `\f`, U+001C–U+001E, U+0085, U+2028, and U+2029.

**D7. Casing.**

- `capitalize()` applies the uppercase mapping to the first grapheme only and leaves the rest
  untouched (`"ǆx"` → `"Ǆx"`). Python titlecases (`ǅ`) and lowercases the tail.
- `upper`/`lower` match Python's full mappings, including `ß` → `SS`, `ﬁ` → `FI`, `İ` →
  `i̇`, and final sigma.

**D8. Graphemes everywhere.** `count`, indexing, `substring`, `reverse`, `pad_*`, search, and
regex positions count extended grapheme clusters, and search matches canonically. Python
counts code points. All 17,758 string cases were compared at grapheme level, with NFC
matching, and agree.

**D9. JSON.**

- A leading BOM is accepted (RFC 8259 allows a parser to ignore it). Python rejects it.
- Integers beyond `Int` parse as `Float` (`12345678901234567890` →
  `1.2345678901234567e+19`).
- `NaN`, `Infinity`, duplicate keys (including NFC-equal ones), lone-surrogate escapes, and
  nesting past 512 levels are refused, as 15.9 says. Python accepts all of them except deep
  nesting.
- Output escapes control characters with uppercase hex (`\u001F`) and writes exponents
  without padding (`1e-7`). Both are valid JSON and differ from Python's text only.

**D10. Base64.** Partial padding (`QQ=`) and non-zero trailing bits (`QR==`) are rejected, as
15.12 says. Python's `b64decode` accepts trailing bits.

**D11. CSV.** A quote inside an unquoted field (`a,b"c`) is read literally, as Python reads
it. RFC 4180 calls it malformed, but 15.11 says only "RFC-style quotes".

**D12. Regex** follows its documented Go/Rust semantics, against which the reference was
written:

- after a match, no empty match where that match ended;
- `$` only at the very end;
- `\d` is ASCII only;
- simple case folding (`STRASSE` does not match `straße`);
- a set never matches a decomposed `é`.

**D13. Smaller items.**

- `Set` has no `to_list()`, although 8.6's general vocabulary lists it. `set.md` documents
  the absence and points to `map`.
- An empty dictionary is written `[]` with a type and prints `[:]`; `[:]` is not accepted as
  input.
- `TimeZone.fixed(hours: -5, minutes: 30)` raises and asks for `minutes: -30`.
  Rewrite-context 15.8 says "its minutes take the sign of its hours", which can be read as
  automatic. `time-zone.md` states the raise, so I treat it as documented.

## What came out clean

- **Regex**, all 3,853 cases: leftmost-first priorities, lazy and greedy counts, alternation
  order, `\b`/`\B`, empty-match rules, split, literal replacement, ignore_case (including
  Kelvin and final sigma), multiline anchors, `escape` for every metacharacter, refused
  features at runtime, and linear time on `(a*)*b` over 5,000 characters.
- **Base64, hex, SHA-256, and HMAC-SHA256** over every length from 0 to 9 bytes and random
  lengths up to 300, with keys longer than the block size, and a 1 MB digest.
- **Dates and times**, all 17,628 cases except the D13 item:
  - month-end clamping, leap years (1600, 1900, 2000, 2100), years 1 and 9999 and the range
    errors past them;
  - days, months, and years until in both directions, including a 29 February birthday;
  - weekday, day of year, and parse/display round trips;
  - Time wrap-around with nanoseconds, DateTime add, `duration_until`, and Duration display,
    `*`, `/` (toward zero), `whole_*`, `total_*`;
  - Unix seconds to local time in nine IANA zones, including Lord Howe's half-hour DST,
    Apia's skipped day, St John's, and Sao Paulo, from 1900 to 2100;
  - `offset_at`, `to_instant` round trips, the New York gap and fold, and flooring of
    negative Unix milliseconds.
- **Int arithmetic**, every overflow boundary of `+ - * // % **` and negation, plus `gcd`,
  `lcm`, `digits`, `factorial` (to 20, with 21 raising), `to_string(base:)` from 2 to 36,
  `format(group_digits:)`, and `abs` of the minimum `Int`.
- **Float display**, every case: shortest round trip, the 1e-6 and 1e16 boundaries, signed
  zero, and specials. Also `floor`, `ceil`, `round` (ties away from zero, including
  0.49999999999999994), `truncate`, `to_int` limits, `square_root`, trig and logs within
  1e-12, and `Math.max`/`min` including signed-zero ties and NaN raising.
- **Lists**, apart from finding 01:
  - stable `sort` and `sort_by` (Ints, Floats with infinities and both zeros, Strings by
    normalized code points);
  - `unique` keeps the first canonically equal item;
  - `frequencies`, `chunks`, `windows`, `zip`, `pairs`, `take`/`drop`, `repeat`, `join`;
  - `reduce`/`reduce_right`, `take_while`/`drop_while`, `unique_by`, `min_by`/`max_by` first
    ties, `count_where`, `one?`, `flat_map`;
  - `sum`/`average` (including Int overflow raising), and NaN raising in sort, max, and
    sort_by.
- **Set algebra** and equality, and **Dict** `merge` order (a key keeps its position and
  takes the new value), equality, `map_values`, `filter`, and `remove`.
- **JSON**, everything except D9's textual and number-kind notes: 400 random nested documents
  round-tripped exactly, including Float spellings (`3.0`, `-0.0`), with keys in document
  order. Also string escapes for every control character, U+2028, U+2029, BOM-like
  characters, and astral characters in both directions; the pretty form's structure; `int()`
  of `3e2` and `3.0`; and the 512-depth limit.
- **CSV**, everything except findings 07 and 08: minimal quoting matched the reference for
  all 300 random tables. Emerald read Python-written CSV (both line endings, `QUOTE_ALL`)
  exactly, and BOM, doubled quotes, embedded newlines, and `parse_records` errors all
  behaved as documented.
- **Strings**, everything except finding 04: casing, trimming, `lines`, `words`, grapheme
  `count`/`chars`/`reverse`/`substring` bounds, canonical grapheme-boundary search
  (`contains?`, `index_of`, `starts_with?`), `pad_*` (including a combining-mark fill), the
  character tests, `to_int` range limits, and `code_points`/`bytes`.
