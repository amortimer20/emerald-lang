# Dates and times: design and implementation plan

Status: accepted design, 2026-09-25. The user accepted every recommendation below and left
remaining judgement calls to the executor; implementation proceeds slice by slice. Read
AGENTS.md and the current handoff before acting; the repository takes precedence over
remembered conversations. At the start of each slice, reread `git status`, the recent
`git log`, relevant diffs, and docs/handoff.md.

The user asked for a date/time API that is **easy to understand and modern**. Rewrite-context
15.7 makes date/time the highest-priority standard-library addition and requires its design
pass to settle time-zone scope and how durations are represented. This plan does both.

## What beginner programs need

The API is judged by these programs. Each one should read naturally and need no knowledge of
epochs, offsets, or format codes:

```emerald
# How many days until my birthday?
const today = Date.today()
var birthday = Date(today.year, 3, 14)
if birthday < today {
    birthday = birthday.add(years: 1)
}
print("#{today.days_until(birthday)} days to go")

# How old is someone?
const born = Date(2011, 6, 2)
print("You are #{born.years_until(Date.today())}")

# What day of the week was it?
print(Date(1969, 7, 20).weekday)        # Sunday

# How long did that take?
const watch = Stopwatch.start()
build_report()
print("Finished in #{watch.elapsed()}")  # Finished in 1.25s

# A countdown
const lunch = Duration(minutes: 45)
print("Back in #{lunch}")               # Back in 45m

# A timestamp for a log line
print("[#{DateTime.now()}] started")    # [2026-09-25T14:30:07] started

# A meeting time somewhere else
const meeting = DateTime(2026, 10, 1, 9, 0).to_instant(TimeZone("America/New_York"))
print(meeting.to_date_time(TimeZone("Europe/Paris")))   # 2026-10-01T15:00:00
```

## Principles

"Modern" here means the lessons of JavaScript's Temporal, java.time, kotlinx-datetime, and
Rust's jiff, and avoiding the traps of older APIs (JavaScript's `Date`, Python's naive vs.
aware `datetime`, C's `struct tm`):

1. **One type per meaning.** A birthday, a time on the clock, a moment in history, and a
   length of time are different things. Each gets a type, so the checker catches mixing them
   up. No one type tries to be all of them.
2. **Exact vs. calendar arithmetic is visible.** Operators (`+`, `-`, `*`, `/`, comparisons)
   do exact, unambiguous arithmetic on `Instant` and `Duration`. Calendar arithmetic, where
   "one month" or "one day" depends on the date, uses named methods with named units:
   `date.add(months: 1)`. Rule to teach: *operators for exact time, words for the calendar.*
3. **Values, not objects.** Every type is an immutable struct: copied, compared by value, and
   usable as a dictionary key or set element. Nothing changes in place.
4. **No off-by-one or numbering traps.** Months are 1–12. Years are written in full. The
   weekday is an enum, not a number, because "Sunday = 0" vs. "Monday = 1" differs between
   systems and a number can't say which is meant.
5. **A plain default display.** Every value prints in ISO 8601 form (`2026-09-25`,
   `14:30:00`, `2026-09-25T14:30:00`, `2026-09-25T18:30:00Z`), which is unambiguous in every
   country and sorts correctly as text. `Duration` prints as `1h 30m`. Custom output comes
   from interpolating components, not a format-code language (15.5).
6. **Errors teach.** Invalid input (`Date(2026, 2, 30)`, `"2026-13-01"`, an unknown zone)
   raises one `DateTimeError` whose message names the component, its value, and the valid
   range.
7. **The time zone is a parameter, never a hidden global.** Functions that need one take a
   `zone` parameter that defaults to `TimeZone.local`. The local zone is decided once per
   execution by the runtime, like Console's color policy (15.6).

## Verified constraints (checked against source and pinned Zig 0.16.0, 2026-09-25)

- **The API can be ordinary Emerald in `src/prelude.em`.** A probe written in user code
  confirmed every feature needed: a struct adopting `Ordered` and `Textual`; `@operator` with
  a same-type `add`, a mixed `Duration * Int`, and a `Duration / Duration` returning `Float`;
  a custom constructor whose parameters all have defaults (`Duration(hours: 1, minutes:
  30)`); an enum adopting `Textual` to display as `Monday`, including inside a list; a struct
  used as a dictionary key; a defaulted parameter reading a type-level field (`zone: TimeZone
  = TimeZone.utc`); and `pad_start` for zero-padding. Console's precedent applies: write the
  library in Emerald so named and defaulted arguments work. Keep native code to a few
  single-purpose primitives. Native dispatch passes arguments by position only (see the
  Console plan).
- **Privacy is per type.** One struct cannot read another's `_field`, even in the prelude.
  Types that need each other's internals (for example `DateTime.to_instant` needing the
  zone's offset) must go through public members or a native primitive. Keep the public
  surface honest: add a public member only if it belongs in the API anyway.
- **Zig provides clocks, not calendars or zones.** `std.Io.Clock.real` is Unix time, UTC with
  leap seconds ignored, in nanoseconds. `std.Io.Clock.awake` is monotonic. `std.time.epoch`
  has leap-year and days-in-month helpers only. `std.tz.Tz.parse` reads TZif files but has no
  offset lookup and doesn't evaluate the POSIX rule in the TZif footer (needed for dates after
  the last listed transition). The interpreter already gets its `Io` from
  `std.Io.Threaded.global_single_threaded.io()`.
- **The execution-wide policy pattern exists.** `emerald.Streams` carries the color policy.
  It defaults to "off" so REPL, Zig, conformance, and fuzz runs stay deterministic, and
  `main.zig` resolves the real value (`ColorPolicy.zig`). The local time zone should follow
  the same pattern: default UTC in `Streams`, resolved from the OS in `main.zig`.
- **Name collisions.** No in-tree program declares `Date`, `Time`, `DateTime`, `Instant`,
  `Duration`, `TimeZone`, `Weekday`, or `DateTimeError`. `conformance/run/traits.em:201`
  declares `struct Stopwatch`. Adding a built-in `Stopwatch` makes that a shadowing warning
  (14.2), which that case's expectation must absorb, or the case renames its struct.
- **Startup cost.** The prelude is parsed and checked on every run. A Debug build runs
  `print(1)` in about 40 ms today. The new prelude code will be several hundred lines.
  Measure before and after the first slice, and record the numbers.

## Proposed API

All types are built-ins in the `Emerald` namespace (15.1). They are written bare and always
reachable as `Emerald.Date` and so on. All are structs with only `const` fields.

| Type | Meaning | Prints as |
| --- | --- | --- |
| `Date` | A calendar date, with no time or zone: a birthday, a due date | `2026-09-25` |
| `Time` | A time on the clock, with no date or zone: an alarm, opening hours | `14:30:00` |
| `DateTime` | A date and time with no zone: what a wall clock and calendar show | `2026-09-25T14:30:00` |
| `Instant` | An exact moment, the same everywhere: a log timestamp, a deadline | `2026-09-25T18:30:00Z` |
| `Duration` | An exact length of time: a timeout, a stopwatch reading | `1h 30m` |
| `TimeZone` | Rules turning an `Instant` into a `DateTime` in some place | `America/New_York` |
| `Weekday` | `monday` through `sunday` | `Monday` |
| `Stopwatch` | Measures elapsed time with the monotonic clock | (a class; see below) |
| `DateTimeError` | Invalid dates, times, text, or zones; `extends RuntimeError` | |

Deliberately not included: a zoned date-time type (kotlinx-datetime's approach: convert with
an explicit zone instead), a calendar-period type (named `add` arguments cover it), non-
Gregorian calendars, locale-aware month and day names, leap seconds, and format patterns.
See "Out of scope".

### `Date`

```emerald
Date(year: Int, month: Int, day: Int)
Date.today(zone: TimeZone = TimeZone.local): Date
Date.parse(text: String): Date                   # raises DateTimeError
Date.parse_maybe(text: String): Date?

date.year, date.month, date.day: Int             # month is 1–12
date.weekday: Weekday
date.month_name: String                          # "September"
date.day_of_year: Int                            # 1–366
date.days_in_month: Int
date.leap_year?(): Bool

date.add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0): Date
date.subtract(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0): Date
date.days_until(other: Date): Int                # negative when other is earlier
date.months_until(other: Date): Int              # whole months
date.years_until(other: Date): Int               # whole years: an age
date.at(time: Time): DateTime
```

`Date` adopts `Ordered` and `Textual`. Structural equality and hashing come by default.

### `Time`

```emerald
Time(hour: Int, minute: Int = 0, second: Int = 0, nanosecond: Int = 0)
Time.now(zone: TimeZone = TimeZone.local): Time
Time.parse(text: String): Time
Time.parse_maybe(text: String): Time?

time.hour, time.minute, time.second, time.nanosecond: Int
time.add(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0): Time
time.subtract(...same units...): Time
```

`Time` wraps around midnight (`Time(23, 0).add(hours: 2)` is `01:00:00`), as java.time and
Temporal do. It adopts `Ordered` and `Textual`. The display is `HH:MM:SS`. Fractional seconds
appear only when nonzero, in groups of 3, 6, or 9 digits (`14:30:00.250`).

### `DateTime`

```emerald
DateTime(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int = 0)
DateTime.now(zone: TimeZone = TimeZone.local): DateTime
DateTime.parse(text: String): DateTime
DateTime.parse_maybe(text: String): DateTime?

date_time.date: Date
date_time.time: Time
date_time.year ... date_time.nanosecond, date_time.weekday   # same as Date and Time
date_time.add(years: ..., nanoseconds: ...): DateTime   # every unit from years to nanoseconds
date_time.subtract(...): DateTime
date_time.duration_until(other: DateTime): Duration   # wall-clock difference, ignoring zones
date_time.to_instant(zone: TimeZone = TimeZone.local): Instant
```

A wall-clock time can occur twice on the day clocks go back, or not at all on the day they go
forward. `to_instant` then resolves the way Temporal's default `"compatible"` does: for a
repeated time, take the earlier moment; for a skipped time, move forward by the length of the
gap (`02:30` on a spring-forward night becomes `03:30`). This never raises, and the library
page must explain it.

### `Instant`

```emerald
Instant.now(): Instant
Instant.parse(text: String): Instant            # requires Z or an offset: 2026-09-25T14:30:00-04:00
Instant.parse_maybe(text: String): Instant?
Instant.from_unix_seconds(seconds: Int): Instant
Instant.from_unix_milliseconds(milliseconds: Int): Instant

instant.unix_seconds: Int                       # rounded toward the past
instant.unix_milliseconds: Int
instant.to_date_time(zone: TimeZone = TimeZone.local): DateTime

instant + duration    # Instant (the method `after`)
instant - duration    # Instant (`before`)
instant - instant     # Duration (`since`)
```

`Instant` adopts `Ordered` and `Textual`. It always prints in UTC with `Z`. To show local
time, convert with `to_date_time()`.

### `Duration`

```emerald
Duration(days: Int = 0, hours: Int = 0, minutes: Int = 0, seconds: Int = 0, milliseconds: Int = 0, microseconds: Int = 0, nanoseconds: Int = 0)

duration.total_days, total_hours, total_minutes, total_seconds, total_milliseconds: Float
duration.whole_days ... whole_nanoseconds: Int      # rounded toward zero
duration.abs(): Duration
duration.zero?(), negative?(): Bool

duration + duration    duration - duration    # Duration
duration * int         duration / int         # Duration (division rounds toward zero at 1 ns)
duration / duration                           # Float: how many times one fits in the other
```

A `Duration` is an exact count of nanoseconds. It may be negative. A "day" in `Duration` means
exactly 24 hours, unlike a calendar day in `add(days:)`. This is the one distinction learners
most often need explained, so the docs show a daylight-saving example. The display lists
nonzero units from largest to smallest: `2d 3h`, `1h 30m`, `45s`, `1.25s` (fractions of a
second as decimal seconds, trailing zeros removed), `0s`, and `-5m` for negative values. It
adopts `Ordered` and `Textual`.

The precision is nanoseconds, matching the OS clocks and every modern library. How it is
stored is private: two normalized `Int`s (whole seconds and nanoseconds) cover far more than
the supported year range, where a single nanosecond `Int` would stop at 1677–2262.

### `TimeZone`

```emerald
TimeZone.utc: TimeZone
TimeZone.local: TimeZone                        # decided once per execution
TimeZone.fixed(hours: Int, minutes: Int = 0): TimeZone    # "+05:30"
TimeZone(name: String)                          # "UTC", "+05:30", or an IANA name such as "Asia/Tokyo"
TimeZone.named_maybe(name: String): TimeZone?

zone.name: String
zone.offset_at(instant: Instant): Duration
```

Two `TimeZone` values are equal when their names are equal. A zone displays as its name.

### `Weekday`

`enum Weekday { monday, tuesday, wednesday, thursday, friday, saturday, sunday }`, adopting
`Textual` so it prints `Monday`. Values are listed Monday first (ISO 8601). As 12 says,
declaration order is not an ordering, and `Weekday` does not adopt `Ordered`: the week is a
cycle, and which day starts it depends on culture.

### `Stopwatch`

```emerald
Stopwatch.start(): Stopwatch
watch.elapsed(): Duration
watch.restart()
```

This is a class, because a stopwatch is a running thing rather than a value. It reads the
monotonic clock, so a program's timing isn't wrecked when the system clock changes.
`Instant.now() - start` stays possible, but the docs point timing questions to `Stopwatch`.
`elapsed()` is a method rather than a property because its answer changes each time it is
called.

Slice 3 notes. `to_instant` and `to_date_time` take their `zone` explicitly until slice 4
adds `TimeZone.local` as the default. `Instant` and `Stopwatch` have no public constructor;
the diagnostic for calling one names `Instant.now()` or `Stopwatch.start()`. `Instant` reads
a `Duration` exactly through `whole_seconds` and `whole_nanoseconds`, because another type's
private fields are out of its reach.

Slice 4 notes. The local zone's rules come from the machine, not the built-in database:
`TZ` and `/etc/localtime` on Unix, `GetDynamicTimeZoneInformation` on Windows. Tests of
clock changes run in `conformance/local-zone/`, where the local zone is `EST5EDT`.
`TimeZone(name)` accepts the local zone's own name until slice 5 adds the rest.

### Parsing

The accepted text is a strict subset of ISO 8601 / RFC 3339, the same as the display format.
Whatever a value prints, its `parse` reads back to an equal value.

- `Date`: `YYYY-MM-DD` with a four-digit year.
- `Time`: `HH:MM`, `HH:MM:SS`, or `HH:MM:SS.fraction` with 1–9 fraction digits.
- `DateTime`: a date, then `T` or one space, then a time.
- `Instant`: a date-time, then `Z` or `±HH:MM`.

Surrounding whitespace is ignored, as for `to_int` (9.4). Everything else, including
`2026-9-25`, `25/09/2026`, and a month name, is rejected. The error message says what was
expected and where it went wrong (`"2026-13-01": month 13 is not between 1 and 12`). Parsing
other layouts is out of scope. A program reading `25/09/2026` can split the string and call
`Date(...)`.

### Ranges and calendar rules

- **The proleptic Gregorian calendar.** Years 1 through 9999, the range that prints as four
  digits. `Date`, `DateTime`, and `Instant` share it. Going outside it raises
  `DateTimeError`, never wraps.
- **Constructors check every field**, and name the bad field and its valid range: February 29
  is valid only in leap years, hours are 0–23, and so on.
- **Adding months or years keeps the day if it can, otherwise uses the last day of the
  month**: `Date(2026, 1, 31).add(months: 1)` is `2026-02-28`. Temporal, java.time, and
  kotlinx-datetime all behave this way. Units are applied from largest to smallest.
- **`years_until` and `months_until` count whole units** and round toward zero, so the answer
  is someone's age, not a rounded guess.
- **Leap seconds are ignored**, as Unix time does. `23:59:60` does not parse.

### Default display for custom formats

Interpolation replaces a format-code language:

```emerald
print("#{date.weekday}, #{date.month_name} #{date.day}, #{date.year}")   # Friday, September 25, 2026
print("#{time.hour}:#{time.minute.to_string().pad_start(2, "0")}")
```

A small set of named readable formats, such as a 12-hour clock or `September 25, 2026`, is a
candidate later slice (decision 5).

## Decisions

All six are settled (2026-09-25): the user accepted each recommendation. For decision 4 the
user left the open part to the executor's judgement, and `Program.sleep` is included in
slice 3. The options that were weighed are kept below as the record of why.

1. **Time-zone scope.** This blocks slices 4–5.
   - **A.** UTC, fixed offsets, and the machine's local zone only. `TimeZone("Asia/Tokyo")`
     does not exist yet. The local zone comes from the OS (`TZ` / `/etc/localtime` TZif on
     Unix, the Win32 time-zone rules on Windows).
   - **B.** A, plus named IANA zones read from the OS time-zone database. This is free on
     Linux and macOS, but Windows has no such database, so the same program would behave
     differently on Windows.
   - **C.** A, plus named IANA zones from a copy of the IANA database built into Emerald
     (public domain; roughly 100–450 KB depending on compaction). Results are the same on
     every OS and in CI. Emerald releases have to pick up database updates, and a
     `tools/update-tzdata.sh` script would regenerate the built-in copy.

   **Settled: C, built as the last slice.** A meeting-in-another-city program is a
   common beginner wish, and matching results everywhere suits a language whose conformance
   tests run on three OSes. Slices 1–4 are the same under A, B, or C, so this decision can
   wait until slice 5.
2. **Positional units.** With the constructor above, `Duration(5)` means five *days*, and
   `date.add(1)` means one *year*: easy to write by mistake and silent. Options:
   - (a) A narrow checker rule: for `Duration(...)`, `add`, and `subtract` on these types,
     every unit argument must be named. `Duration(5)` gets a diagnostic suggesting
     `Duration(seconds: 5)`. No new syntax.
   - (b) A general "named-only parameter" feature in the language. This is new surface area
     (rewrite-context 7.3) and needs its own design pass.
   - (c) Factories only: `Duration.seconds(5)`, `Duration.minutes(30)`. These are clear but
     can't combine (`1h 30m` needs `+`), and are a second way to build the same thing.

   **Settled: (a).** It is the least new machinery, and it fits "errors are pedagogy".
   Generalize it into (b) only if a second library wants the same rule.
3. **`Month`: number or enum.** Settled: an `Int` (1–12) plus `month_name`,
   because month numbers are universal, beginners write `date.month == 12`, and `Date(2026,
   9, 25)` stays short. A `Month` enum would make `Date(2026, Month.september, 25)` the
   canonical form, which is safer but noisier. Weekday is the enum because its numbering is
   *not* universal.
4. **`Stopwatch` and sleeping.** Settled: include `Stopwatch`, and also
   `Program.sleep(duration: Duration)`, a blocking pause, for countdowns and simple animation.
   It fits the single-threaded model (21) and has an obvious beginner use. Both land in
   slice 3.
5. **Readable formats.** Settled: ship ISO display plus components first, and decide
   on a small named-format set (such as `date.format(style: DateStyle.long)` →
   `September 25, 2026`, and a 12-hour `Time` form) after real programs show which ones
   people use. All output stays English and locale-independent (15.5).
6. **Names.** The proposal uses `Time` (Python and Swift readers may expect a moment rather
   than a clock reading; `TimeOfDay` is the alternative), `DateTime` rather than Temporal's
   `PlainDateTime` or java.time's `LocalDateTime`, and `Instant` (java.time, Temporal, and
   kotlinx all use it). Settled: keep the short names. The type table and the error
   message for mixing them up do the teaching.

## Implementation approach

- **Mostly Emerald, a little native code.** Calendar math (days-from-civil conversion in
  Int arithmetic), validation, arithmetic, parsing, and display all live in `src/prelude.em`.
  Keeping them in Emerald means any future backend inherits them unchanged (principle 5), and
  named and defaulted arguments work. Native primitives, each a single-purpose hidden
  type-level function like `Console._color`:
  - `Instant._now(): (Int, Int)`: `Clock.real`, as seconds and nanoseconds.
  - `Stopwatch._ticks(): Int`: `Clock.awake` nanoseconds.
  - `TimeZone._local_name(): String`: the execution's resolved local zone.
  - `TimeZone._offset_seconds(name: String, unix_seconds: Int): Int` and
    `TimeZone._known?(name: String): Bool`: zone lookup (slices 4–5).
- **Deterministic by default.** Add `time_zone` to `emerald.Streams`, defaulting to UTC, so
  Zig tests, conformance, fuzz, and REPL tests never depend on the host's zone. `main.zig`
  resolves the real local zone for `run`, `test`, and `repl` in a pure, unit-tested function,
  like `ColorPolicy`. If a Zig test needs a fixed "now", add an optional clock override to
  `Streams` at the same time. Don't add one speculatively.
- **Zone lookup (slices 4–5)** is new Zig in its own file (`src/TimeZone.zig`): search the
  transitions, then evaluate the POSIX `TZ` footer rule for later dates. Unit-test it against
  known transitions (US and EU daylight-saving changes, a zone that dropped DST, a
  half-hour-offset zone, the southern hemisphere).
- **Checker work** is limited to decision 2's named-unit diagnostic, if accepted.
  Everything else is ordinary prelude code that the checker, formatter, and LSP already handle
  (hover and completion come free from the prelude signatures).

## Slices

Each slice is independently runnable, committed separately, and follows AGENTS.md's
validation list: Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh`, `zig fmt --check src/*.zig`, `git diff --check`. Each
slice's rewrite-context text is written in the same change as its code (23.6).

1. **`Duration`, `Date`, `Weekday`, `DateTimeError`** (pure; no clock). Construction and
   validation, components, `weekday`, `day_of_year`, `leap_year?`, `add`/`subtract` with
   month-end clamping, `days/months/years_until`, `Duration` arithmetic, `total_*`, display,
   parsing. Conformance: `run/date-basics`, `run/duration-basics`, `diagnostics/` and
   `runtime-errors/` for invalid components and bad text. Edge cases: 1900 (not a leap year),
   2000 (leap), Feb 29 plus one year, Jan 31 plus one month, year 1 and year 9999 bounds,
   negative durations, overflow. Measure prelude startup cost.
2. **`Time` and `DateTime`** (pure). Midnight wraparound, `at`, `duration_until`, the parse
   and display round trip, fractional-second display.
3. **`Instant`, the clock, `TimeZone.utc`/`fixed`, `Stopwatch`, `Program.sleep`.**
   `Instant.now()`, Unix conversions, operators, offset parsing, `to_date_time`/`to_instant`
   with fixed zones. Tests assert relations (`later >= earlier`, a stopwatch reading is
   non-negative), never the actual current time. Resolve the `conformance/run/traits.em`
   `Stopwatch` collision.
4. **The local zone.** `TimeZone.local`, `Date.today()`, `Time.now()`, `DateTime.now()`, and
   the `Streams.time_zone` plumbing. OS detection runs through the pure resolution function.
   Daylight-saving gap and overlap resolution is tested through an injected zone. Windows is
   verified by CI, as Console's VT setup was.
5. **Named zones** (per decision 1). `TimeZone(name)`, `named_maybe`, and the data
   source with its update script. Conformance on real transitions, such as America/New_York
   on the 2026 spring-forward and fall-back days, and Asia/Kolkata's half-hour offset.
6. **Documentation and integration.** Library pages (`date.md`, `time.md`, `date-time.md`,
   `instant.md`, `duration.md`, `time-zone.md`, or a combined page if that reads better), an
   inventory entry, rewrite-context 15.8 plus decision-table rows in 22, an update to 15.7,
   `examples/dates.em` covering the beginner programs above, and a fuzz-template entry if the
   generator's value shapes can reach these types cheaply.

## Out of scope for this milestone

Zoned date-time type, calendar-period type, date ranges (`for day in start..end`; the
`Range` type is `Int`-only), non-Gregorian calendars, locale-aware names and formats, format
patterns (`%Y-%m-%d`), parsing arbitrary layouts, relative phrases ("3 days ago"), leap
seconds, and time-zone abbreviations (`EST`) as input. Each can be revisited if a real program
shows the need (24).

## Risks

- **Prelude growth** raises the cost of every run. Mitigation: measure in slice 1. If needed,
  move the heaviest calendar routines to native code behind the same Emerald signatures.
- **Zone data freshness** under option C. Mitigation: the update script plus a release
  checklist line.
- **Named-unit rule creep.** If decision 2(a) starts growing exceptions, stop and
  propose 2(b) as a proper language feature.
