# Review area 8: what ties the language to the interpreter

Roadmap item 10, area 8 of [codebase-review-plan.md](../codebase-review-plan.md). Reviewed
2026-10-29 on `claude/review-portability`, Zig 0.17.0, macOS only (none of these findings
depends on the platform, apart from the OS limits noted in the clean list).

The question was what a native compiler could not reproduce from the spec alone: behavior a
program can observe that the spec leaves open, or states differently. Every finding below has a
program in [`repro/portability/`](repro/portability/), with its output captured next to it as
`NN-name.out`. Each one is run with `emerald run NN-name.em` from that directory. The
exceptions are `07-file-init-triggers/` (`emerald run main.em` inside it) and
`15-test-order-and-state/` (`emerald test main.em`).

**Counts:** 20 findings: 3 contradictions (c), then 17 places where the spec is silent and the
interpreter's choice can be observed (b). 34 behaviors checked out as covered (a).

Ranking: contradictions come first. Within each group, the findings that block the compiler
against the existing conformance suite come before the ones that only need a spec sentence.

---

## Contradictions (c)

### C1. `is` and `type_name` on a generic `T` value use the static type, not the runtime type
[`01-generic-is-and-type-name.em`](repro/portability/01-generic-is-and-type-name.em)

```
T false false        # describe(3): x.type_name, x is Int, x is String
Int                  # the same value, returned and asked outside
T false false        # describe("text")
inside: List[T]
outside: List[Int]   # the same list, asked after it is returned
```

- **Spec:** 4.4 says "`is` tests a runtime type" and `type_name` uses "Emerald's source spelling
  for its concrete runtime type". 11.3 says only that a generic *value's* `type_name` drops its
  arguments (`Pair`).
- **Cause:** `valueIs` and `writeTypeName` (`src/Interpreter.zig` ~3141 and ~3171) answer from
  the checker's static type for every non-object value. Inside a generic body that type is `T`,
  so `3 is Int` is `false`, with no warning. A monomorphizing compiler would naturally answer
  `true` and `Int`.
- **Proposed sentence (11.3):** "Inside a generic body, `is` and `type_name` see the value's
  runtime type, as they do everywhere else: a `T` holding `3` is an `Int`, and a `List[T]` built
  there spells the element type the call gave `T`." If the interpreter cannot keep the
  arguments, the other option is to reject `is` and `type_name` on a `T`, the same way 11.3
  already rejects `==` and members.

### C2. `map_keys` with colliding keys returns a smaller dictionary
[`02-map-keys-collision.em`](repro/portability/02-map-keys-collision.em)

```
["ava": 3] 1 3
```

- **Spec:** `docs/library/dict.md` says `map_keys` produces "a new `Dict` the same size as the
  receiver". rewrite-context 8.6 does not say which entry survives a collision. The interpreter
  keeps the first key's position and the last value, which is the `associate` rule.
- **Proposed sentence (8.6 / dict.md):** "When `map_keys` produces the same key twice, the
  result has one entry for it, at the first position, holding the last value, as `associate`
  does; it can therefore be smaller than the receiver."

### C3. A string displayed inside a collection does not escape `#{` or control characters
[`03-string-display-escapes.em`](repro/portability/03-string-display-escapes.em)

```
["#{x}", "5"]
["bell^G", "escape^[[31m", "delete^?"]     # shown with cat -v; the bytes are raw
```

- **Spec:** 8.5 says "a list displays the way it is written". 15.2 says a string in a collection
  is "quoted, with escapes where needed". `"\#{x}"` displays as `"#{x}"`, which would
  interpolate if written that way. BEL, ESC and DEL are written raw, so a printed list can move
  the terminal cursor or restyle it. `writeQuoted` (`src/Value.zig:462`) escapes only `" \ \n \t
  \r \0`, although its own comment says "as a double-quoted literal would write it".
- **Proposed sentence (15.2):** "Inside a collection a string displays as a double-quoted
  literal that reads back as the same text: `"`, `\`, and `#{` are escaped, `\n`, `\t`, `\r`,
  and `\0` use their escapes, and any other control character is written `\u{...}`."

---

## Silent but observable (b)

### S1. The conformance suite encodes a recursion limit of exactly 1,000
[`04-recursion-limit-encoded.em`](repro/portability/04-recursion-limit-encoded.em)

```
deepest frame reached: 999
```

- **Spec:** 7.2 says "The precise limit above the portable minimum is a resource boundary
  rather than program semantics." But `conformance/runtime-errors/recursion-limit.expected` and
  `constructor-recursion.expected` both contain `(999 times)`. A compiler with any other limit
  fails both cases, even though it meets the spec. This is the most direct blocker in this
  report.
- **Proposed sentence (7.2), or a runner change:** "The repeated-frame count in a recursion
  trace is not part of conformance." Then make the runner normalize `(N times)`, or rewrite the
  two cases to recurse a fixed 1,200 levels deep so they do not depend on the limit.

### S2. Runtime error message text can be read by programs, and no section specifies it
[`05-error-message-text.em`](repro/portability/05-error-message-text.em)

```
index 5 is outside this list, which has 3 elements
floor division by zero
addition of 9223372036854775807 and 3 overflows Int
"x" is not a whole number
```

- **Spec:** 5.3 and 5.4 say what an overflow or index diagnostic must *name*, not its words.
  `error.message` hands the words to the program. 49 `conformance/run/` cases print the
  `.message` of an interpreter-raised error, and 77 `runtime-errors/` cases compare the full
  text. So the compiler can only pass by copying every string in `Interpreter.zig`.
- **Proposed sentence (13.1):** "The message text of interpreter-detected errors is part of
  the language contract and is listed in [an appendix / `docs/library/errors.md`]; a backend
  reproduces it exactly." The alternative is to say the text is not portable, and stop
  `run/` cases from printing it.

### S3. Constructing a subclass does not set up the base class's type-level fields
[`06-subclass-type-setup.em`](repro/portability/06-subclass-type-setup.em)

```
constructing a Dog
  setting up Dog.dogs
constructing an Animal
  setting up Animal.made
```

- **Spec:** 10.4 and 14.1 say type-level fields are set up "the first time the type is
  constructed". `Dog()` runs `Animal`'s construction (10.2: "Base construction finishes
  before derived field defaults"), but `Animal`'s fields wait.
- **Proposed sentence (10.4):** "Constructing a subclass constructs its base: the base's
  type-level fields are set up first, then the subclass's."

### S4. What initializes a module file depends on how its type is reached
[`07-file-init-triggers/`](repro/portability/07-file-init-triggers/)

```
call a type-level function
hello
use an enum value
Mood.happy
construct the class
  setting up greeting
```

- **Spec:** 14.1 says a file "initializes once when one of its members is first accessed". It
  never says whether a type declared in the file is a member, or whether the type's own members
  are. `reach` (`src/Interpreter.zig:2705`) treats a type-level member as belonging only to its
  type. Constructing the type goes through `reachFile`.
- **Proposed sentence (14.1):** "A type declared in a file is one of its members: constructing
  it, calling one of its type-level functions, or naming one of its enum values first
  initializes the file, then sets up the type." (Or the reverse, but one rule for all three.)

### S5. The order of a set produced by set algebra
[`08-set-algebra-order.em`](repro/portability/08-set-algebra-order.em)

```
{3, 1, 2, 4} {2, 4, 3, 1}
{3, 2} {2, 3}
{1, 4} {4, 1}
```

- **Spec:** 8.4 fixes insertion order, but nothing says in what order `union`,
  `intersection`, `difference`, and `symmetric_difference` insert their results.
  `conformance/run/set-operations.expected` encodes the receiver-first order.
- **Proposed sentence (8.6 / set.md):** "A set operation's result keeps the receiver's order
  for the receiver's elements, followed by `other`'s remaining elements in `other`'s order."

### S6. How many times `equals`, `hash`, and `compare` are called
[`09-callback-call-counts.em`](repro/portability/09-callback-call-counts.em)

```
  hash 0
  hash 8
contains:
  hash 8
  equals 8 8
true
compare calls in sort: 69
```

- **Spec:** 8.6 pins block calls to "exactly once per visited value", and 8.4 says hash
  *values* are not output. Nothing covers how often a type's own `equals`, `hash`, or
  `compare` runs. That depends on the hash table's probing, and on the run length of 8.6's
  "merge of insertion-sorted runs".
- **Proposed sentence (8.4):** "How many times, and in what order, a collection calls a type's
  `equals`, `hash`, or `compare` is unspecified; a program whose output depends on it is not
  portable."

### S7. Plain indexed assignment, and a right side that replaces its target
[`10-indexed-assignment-order.em`](repro/portability/10-indexed-assignment-order.em)

```
index 5 is outside this list, which has 1 element      # compound: right side never runs
plain right side                                       # plain: right side runs, then the check
index 5 is outside this list, which has 1 element
[10]                                                   # ys[0] += replace_ys(), with ys = [7] inside
```

- **Spec:** 5.2 orders compound assignment ("checks and reads the current value, then
  evaluates the right side"). For plain `a[i] = v` it says nothing about when the bounds check
  happens. Nor does it say where the write lands when the right side gives the binding a new
  list: the interpreter writes `1 + 9` into the *new* list.
- **Proposed sentence (5.2):** "A plain indexed assignment evaluates its receiver and index,
  then the right side, then checks the index; the write goes to the binding's value at that
  moment."

### S8. `print` renders its arguments after evaluating all of them; interpolation renders as it goes
[`11-print-render-timing.em`](repro/portability/11-print-render-timing.em)

```
Counter(n: 1) 1
Counter(n: 1) 2
```

- **Spec:** 15.2 says only that the arguments "evaluate left to right". 5.1 says an
  interpolation "displays its value as `print` would". In `print(c, bump(c))`, `c` shows the
  state after the bump. In `"#{c} #{bump(c)}"`, it shows the state before.
- **Proposed sentence (15.2):** "`print` evaluates every argument, then displays them in order;
  an interpolation displays each part when it is evaluated."

### S9. When a blocked sender's message enters freed channel space
[`12-channel-handoff.em`](repro/portability/12-channel-handoff.em)

```
send 0
send 1
got 0
got 1
send 2
got 2
```

- **Spec:** 15.13 orders the tasks that are ready to run. It does not say whether a receive
  that frees buffer space moves the waiting sender's message in immediately (as here, so the
  receiver's next receive succeeds without yielding), or only when the sender next runs. That
  choice changes the interleaving.
- **Proposed sentence (15.13):** "When a receive frees space, the longest-waiting sender's
  message is committed into the buffer at once and that sender becomes ready."

### S10. The exact debug display of structs and classes, private fields included
[`13-display-form.em`](repro/portability/13-display-form.em)

```
Dog(name: "Rex", _secret: 7, breed: "lab")
Point(x: 1, _tag: "p")
```

- **Spec:** 10.1 and 15.1 say only "field by field" and "a useful field-based debug
  representation". The spec does not give the `Name(field: value, ...)` syntax, the quoting of
  string fields, that private fields appear, or that base-class fields come first.
  `conformance/run/private-members.expected` encodes `Counter(_count: 4, step: 2)`.
- **Proposed sentence (15.1):** "A struct or object without `Textual` displays as
  `Name(field: value, ...)`, every stored field including private ones, base-class fields first,
  each in declaration order, each value displayed as it would be inside a collection."

### S11. String ordering's normalization form
[`14-string-order-normalization.em`](repro/portability/14-string-order-normalization.em)

```
false false true
["e", "f", "é"]
```

- **Spec:** 9.2 says ordering compares "normalized code points" but does not name the form.
  Under NFC, `é` (U+00E9) sorts after `f`. Under NFD it sorts between `e` and `f`.
- **Proposed sentence (9.2):** "Ordering compares the NFC code points of both strings."

### S12. Test order, and state shared between tests
[`15-test-order-and-state/`](repro/portability/15-test-order-and-state/)

```
zeta sees 1
alpha sees 2
2 tests passed.
```

- **Spec:** 16.3 says "Ordering should be deterministic" and tests "run independently
  enough". The interpreter runs tests in declaration order, and they share module `var` state.
- **Proposed sentence (16.3):** "Tests run in declaration order, file by file in sorted path
  order, and share one program state: a module binding is initialized once and keeps changes one
  test makes."

### S13. FileWriter text can be read before `close`
[`16-writer-visibility.em`](repro/portability/16-writer-visibility.em)

```
[live]
```

- **Spec:** 13.3 and 15.3 do not say whether `FileWriter.write` is visible to other reads
  before `close`. The interpreter writes through unbuffered. A backend that buffers would print
  `[]`.
- **Proposed sentence (15.3):** "Text written to a `FileWriter` is visible to any read of the
  file as soon as `write` returns."

### S14. Running out of memory
[`17-out-of-memory.em`](repro/portability/17-out-of-memory.em)

```
emerald: ran out of memory
[exit 70]
```

- **Spec:** No section covers it. The error cannot be caught, it has no Emerald stack trace
  (13.2 asks for one on unhandled errors), and the exit status is 70. The size computation
  (`2 × max`) overflowing is not reported as an Int overflow either.
- **Proposed sentence (13.1):** "Exhausting memory ends the program with a message and a
  nonzero status, is not catchable, and does not run `finally`; an operation whose result size
  does not fit in `Int` raises the ordinary overflow `RuntimeError` first."

### S15. Deadlock diagnostics number channels
[`18-deadlock-channel-numbers.em`](repro/portability/18-deadlock-channel-numbers.em)

```
At `18-deadlock-channel-numbers.em:7`, the program is waiting to send to channel 2.
```

- **Spec:** 15.13 asks for "channel directions and their original source locations". The
  number is a creation counter. `runtime-errors/channel-send-deadlock.expected` and
  `channel-receive-deadlock.expected` encode `channel 1`.
- **Proposed sentence (15.13):** "A channel in a deadlock diagnostic is named by where it was
  created", or "channels are numbered from 1 in creation order".

### S16. The operand and literal-entry order the spec does not name
[`19-operand-and-entry-order.em`](repro/portability/19-operand-and-entry-order.em)

```
left of +, right of +, base, exponent, left of ==, right of ==,
key 0, value 0, key 1, value 1, index, value
```

- **Spec:** 5.2 covers "Function arguments and other ordered expression lists" and compound
  assignment. Binary operands (including right-associative `**`), whether a dictionary
  literal's keys and values interleave, and the target-before-value order of a plain assignment
  are each only implied.
- **Proposed sentence (5.2):** "Binary operands evaluate left to right whatever the operator's
  associativity; a dictionary literal evaluates each key, then its value, entry by entry; an
  assignment evaluates its target's receiver and index before its right side."

### S17. What makes a duplicate dictionary literal key "statically known"
[`20-duplicate-literal-keys.em`](repro/portability/20-duplicate-literal-keys.em)

```
[(1, 2): "second"]
```

- **Spec:** 8.4 says "A statically known duplicate dictionary literal key is an error". `[1:
  "a", 1: "b"]` and `[1.0: …, 1: …]` are rejected, but a repeated tuple of literals is
  accepted. Whether the program compiles depends on a definition the spec never gives.
- **Proposed sentence (8.4):** "Statically known keys are the ones 6.3 calls known duplicates:
  literals and enum values, and tuples made only of them."

---

## Clean list (a): stated and followed

Each of these was probed with a side-effecting program. "Case" names the conformance case that
exercises it, where there is one.

1. Function arguments evaluate left to right (5.2): case `print-arguments`.
2. Explicit arguments run in written order, then omitted defaults in parameter order (7.3):
   case `defaults-and-named-arguments`.
3. Generated-constructor field defaults run after explicit arguments, in declaration order
   (10.2, via 7.3).
4. Compound assignment evaluates and checks its target before the right side (5.2): case
   `changing-method-arguments`.
5. Destructuring assignment evaluates the whole right side first (8.2).
6. `and` and `or` short-circuit, and a chained comparison evaluates its middle operand once (5.2).
7. The value-producing `if` runs only its chosen answer (6.2). `case` evaluates its alternatives
   in order until one matches (6.3): case `case`.
8. `?.` skips its call arguments when the receiver is `nothing` (4.4).
9. `.or(fallback)` evaluates the fallback only when the value is absent (decision table,
   "Laziness of `or`").
10. Dictionary and set insertion order, the replace-keeps-position rule, and moving a removed
    and reinserted key to the end, including after 99 removals (8.4).
11. `merge` order, `group_by` and `frequencies` first-appearance order, and `to_set` keeping the
    first position (`dict.md`, `list.md`): case `list-grouping`.
12. Dictionary and set equality ignore order (8.4).
13. Closures capture by reference, and loop bindings are fresh per iteration, including a `var`
    inside a `while` body (6.1, 7.4).
14. `for` over a mutated dictionary, and `each` or `map` over a list that the block reassigns or
    appends to, see the snapshot (4.3, 8.4).
15. NaN: `==` is false even for the same list, struct, or tuple through a copy, with no
    identity shortcut, and `contains?` and `unique` follow (5.3, 8.4).
16. `-0.0` and `0.0` collapse as one set element or dictionary key, keeping the first (8.3).
17. Mixed `Int`/`Float` equality is exact (`9007199254740993 == 9007199254740992.0` is false)
    (4.4).
18. Float display: shortest round-trip, `1e+16` and `1e-7` boundaries, `-0.0`, `Infinity`,
    `NaN` (9.4): case `float-display`.
19. Int overflow raises for every operator, negation, `abs`, `**`, `//`, `factorial`, `lcm`,
    `gcd`, and conversions. `%` of the minimum by `-1` is `0`. `sum` checks every addition
    (5.3, 8.6).
20. Ranges at the `Int` limits iterate and step without overflowing, and `(min..max).count`
    raises (6.4).
21. Range display, including empty ranges and `reverse()` shown as `down_to` (6.4).
22. A class cycle displays as `Name(...)` (10.1): case `class-nesting`.
23. A function displays as `<func name>`, a lambda as `<lambda>`, a dictionary as `[k: v]`, a
    set as `{…}` (decision table).
24. `type_name` outside generic bodies: a class's runtime class, a tuple position by position,
    a collection's static type, `Nothing` for an absent optional (4.4).
25. Builtin `hash()` values are printable but no conformance case depends on a value, only on
    equality (8.4): case `generics-constraints`.
26. Seeded `Random` sequences are not encoded in any expected file (`random.md`): case
    `randomness`.
27. Constant division by zero and constant overflow are raised at run time and are catchable,
    not folded into check errors (5.3).
28. A failed module or type setup re-raises the original error on later access (14.1): case
    `caught-setup-errors`.
29. An initialization cycle across files is a runtime error naming the binding (14.1): case
    `runtime-errors/initialization-cycle`.
30. A function call into a module file initializes it, since functions are members (14.1): case
    `module-initialization`.
31. Task scheduling: `start` queues, the parent runs until it waits, and ready tasks resume in
    readiness order (15.13).
32. Recursion of at least 1,000 active calls works through `map` callbacks, getters, and nested
    lambdas (7.2): case `run/recursion-error`.
33. In test mode an entry-file binding initializes only when a test reaches it, and other
    statements do not run (16.3).
34. Forgotten `FileHandle`s are never closed by a collector fallback. After about 10,237 opens
    on macOS, `File.open` raises `FileError`. 13.3 allows this ("correctness must not depend on
    when that happens"), but the count is set by the OS, so a program that leaks handles behaves
    differently by platform.

### Seen in passing, outside this area

- Building a recursive enum of N links copies the whole chain on each `link`, so it takes
  quadratic time (20,000 links take 9 s in a Debug build). This is performance, not portability,
  for area 7.
