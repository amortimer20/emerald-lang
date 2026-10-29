# Area 7: error messages against students' mistakes

Review of Emerald's diagnostics against a corpus of the mistakes novices are known to make
(codebase-review-plan sections 4 and 8; rewrite-context sections 1, 2 and 17). Report only:
nothing under `src/`, `build.zig` or the existing tests was changed.

Run on 2026-10-28, branch `claude/review-errors`, Zig 0.17.0, macOS (Darwin 27). Linux and
Windows were not tried; nothing here looks platform-specific.

## How to reproduce

```text
mise exec -- zig build -j1
docs/review/repro/errors/run.sh
```

`run.sh` runs `emerald check` on every program in `docs/review/repro/errors/corpus/`, runs
`emerald run` (stdin `21`, 5-second timeout) on the ones that check clean, and writes:

- `results.txt`, the first diagnostic of each program in full;
- `results.tsv`, one row per program: the line of the mistake (taken from the program's header
  comment), the first diagnostic's line, and an automatic place check (same line, or the
  line just before).

The other three questions (right problem, a help that fixes it, plain words) were judged by
hand, from `results.txt`. Where a help was in doubt, it was applied literally and the program
run again; those cases are quoted in the findings.

## The corpus

**314 programs.** Each holds one mistake, written as the Emerald program a beginner would
write. The first line of each names the mistake, the line it is on, and its source, for
example:

```text
# Mistake: = instead of == in an if (line 3). Source: Altadmri & Brown 2015 (Blackbox), mistake A; review brief list.
```

Sources, with the number of programs that cite each first:

| Source (the first one cited) | Programs |
| --- | --- |
| Altadmri & Brown 2015, "37 Million Compilations" (Blackbox/BlueJ): their mistakes A to R (`=` for `==`, brackets, `&` for `&&`, semicolon after `if`, `for` separators, keywords as names, wrong arguments, missing `()`, `=>` for `>=`, ignored results, missing `return`, types in calls, return-type mismatch, unimplemented interface) | 51 |
| Kohn 2019, "The Error Behind the Message" (Python novices: `NameError`, `TypeError`, `ValueError`, `AttributeError`, indentation and colons, string and number mixing) | 29 |
| Jadud 2006; Denny, Luxton-Reilly & Tempero 2012; McCall & Kölling 2019; Becker et al. 2016/2019; Pea 1986; Hristova et al. 2003 | 14 |
| Habits carried over from Python | 71 |
| Habits carried over from Java, C, C#, C++ | 54 |
| Habits carried over from JavaScript | 15 |
| Habits carried over from Ruby | 10 |
| Habits carried over from other languages (Rust, Kotlin, Swift, PHP, Lua, Pascal, BASIC, SQL, shell, maths notation) | 10 |
| The review brief's list (off-by-one, infinite loops, integer division, shadowing, `const`, optionals) | 26 |
| Mistakes the guide itself shows, under `docs/language/` and rewrite-context (including the two controls) | 32 |
| Other (a floating-point surprise; an assertion-message check) | 2 |

Many programs cite more than one source; the table counts the first. Ten programs turned out
to be accepted by design in Emerald (single quotes are raw strings; `not x == 5` means what
the student meant; a `for` loop visits a snapshot; and so on), and are marked "by design"
below. They stay in the corpus, since a student will still write them, but they are left out
of the pass rate.

## Results

**304 programs with a real mistake. 152 pass all four questions: 50%.**

| Question | Fails | Rate |
| --- | --- | --- |
| No diagnostic at all for a real mistake | 12 | 4% |
| Right problem (the first diagnostic names the real mistake) | 54 more | 78% pass, counting the 12 silent ones as fails |
| Right place (the first diagnostic's line is at, or just before, the mistake) | 5 | 98% pass |
| Help fixes it (following the help literally works, or moves on to the next real problem) | 134 | 54% pass |
| Plain words | 12 | 96% pass |

The checker is strong where it already knows the mistake. `=` in a condition, `&&`, `||`, `!`,
`++`, `? :`, `??`, semicolons, `.length`, `.push`, `.pop`, `this`, a missing `self.`, a
missing `@override`, `const` changes, optionals, empty ranges written high to low, integer
division into an `Int`, and the runtime errors (index, overflow, division by zero, recursion,
dictionary misses, failed asserts) all name the mistake, point at it, and say what to write.

It is weak in two places. First, a word Emerald does not know at the start of a statement
(`def`, `elif`, `let`, `function`, `switch`, `throw`, `unless`, a misspelled keyword) is
reported as "this result is never used", with a help about `score += 1`. Second, the help for
an unknown name never suggests a close spelling or the Emerald name for another language's
function, though rewrite-context 17.2 asks for both, and the member table that does this for
`.length` and `.push` has no counterpart for `len`, `int`, `str`, `null`, `True` or `range`.
Those causes (F1, F15, F16 below) account for 63 of the 152 failures.

Place is nearly always right. The five misses are a missing `)` reported on the next line, two
constructs reported at their header rather than at the line that is wrong, and an infinite loop
reported at the line after it.

## Findings

Ranked as the brief asks: no diagnostic or the wrong problem first, then wrong place, then a
help that does not fix it, then wording. Each finding is one cause.

### No diagnostic, or the wrong problem

**F1. An unknown word at the start of a statement is reported as "this result is never used".**
Programs: 013, 025, 026, 027, 033, 043, 053, 054, 062, 063, 064, 128, 138, 145, 146, 147, 170,
186, 187, 265, 269, 278, 296 (23 programs, the largest single cause).

```text
025-elif.em:6:1: this result is never used
  elif x > 3 {
  ^^^^
Assign it to a name, or call a function that does something with it. `score + 1` on its own is usually meant to be `score += 1`.
```

The same message comes for `def`, `function`, `fn`, `let`, `int count = 0`, `foreach`,
`switch`, `throw`, `until`, `unless`, `elsif`, `elseif`, misspelled keywords (`fucn`, `retrun`,
`whlie`), `print "hello"`, `Dog rex = Dog("Rex")`, `lives--`, `score == 10` (meant `=`), a
function name with no `()` (`say_hello`), and a Ruby-style last expression meant as the
result (`n * 2` in place of `return n * 2`). It fails right problem: the word is unknown, or
the line is meant as a declaration or a call, not a discarded value. The help's `score += 1`
example matches none of them. `++` and `&&` already have their own messages, so this is a gap
in the same table, and `unless` is one the guide itself names ("there is no `unless`; write
`if not`").
**A good message** names the word and the Emerald spelling: "`elif` is not an Emerald
word; write `else if`", "functions start with `func`", "`switch` is written `case`", "`throw`
is written `raise`", "add `()` to call `say_hello`", "write `return n * 2` to give back the
value".

**F2. Calling a method that returns a new value and dropping the result is silent.**
Programs: 157, 158, 159, 160.

```text
var name = "  Ava  "
name.trim()
print("[" + name + "]")      # prints [  Ava  ], no diagnostic
```

The same holds for `scores.sort()`, `shout.upper()`, and a user function's `Int` result.
Altadmri & Brown's mistake N ("method result ignored") is among the most frequent in Blackbox.
It fails as no diagnostic: the checker already warns "this result is never used" for
`score == 10`, but not for a call whose only effect is its result. `sort` beside `sort!` makes
this especially likely in Emerald.
**A good message** says: "`trim()` gives back a new String and leaves `name` as it was;
write `name = name.trim()`" (and for `sort`, "or call `sort!()` to sort in place").

**F3. An infinite loop gets no diagnostic, and `while true` with no `break` gets the wrong one.**
Programs: 177, 179 (silent; they run until the 5-second timeout), 178.

```text
178-infinite-while-true.em:6:1: warning: this code can never run
  print(tries)
  ^^^^^^^^^^^^
Every path above it already returns, raises, breaks, or continues. Remove it, or move it earlier.
```

177 (`while i < 5` whose body never changes `i`) and 179 (a counter moving away from its
bound) print forever. In 178 the warning is correct, but it points at the line after the
loop and gives a reason that is not true: nothing above returns, raises, or breaks; the loop
has no `break`. It fails no diagnostic (177, 179) and right problem and place (178).
**A good message** for 178 points at `while true` and says "this loop has no `break`, so it
never ends and the code after it never runs"; for 177, a warning that "`i` is never changed
inside this loop, so its condition never changes".

**F4. The misleading-indentation warning that rewrite-context 17.2 promises does not exist.**
Program: 024.

```text
print("low") if score < 50
    print("try again")       # runs every time, no warning
```

17.2 says the checker "warns only when indentation strongly depicts a different brace
scope — for example, a line visually nested beneath a statement that opened no block". This is
that example, and nothing is reported. It fails as no diagnostic, and as an untested rule.
**A good message:** "this line is indented as though it belonged to the `if` above, but a
trailing `if` guards one statement only; put both in `if score < 50 { ... }`".

**F5. Interpolation written the way other languages write it is printed literally.**
Programs: 118, 119 (silent), 117 (the wrong problem).

`print("Hello ${name}")` prints `Hello ${name}` and `print("Hello {name}")` prints
`Hello {name}`; `print(f"Hello {name}")` gives "expected `)` to close this call, found a
string". When the text inside `${...}` or `{...}` is a name in scope, the student almost
certainly meant interpolation.
**A good message** warns "`${name}` is printed as written; Emerald interpolates with
`#{name}`", and for `f"..."`, "Emerald strings need no `f`; write `"Hello #{name}"`".

**F6. Printing a function's `Nothing` result is silent.**
Programs: 161, 212.

`print(greet("Ava"))`, where `greet` prints and returns nothing, prints an extra `nothing`;
`print(scores.sort!())` prints only `nothing`. McCall & Kölling list "printing the result of
a function that returns nothing" as a common novice error.
**A good message** warns "`sort!()` changes `scores` and gives back nothing; print `scores`
after it".

**F7. Operators from other languages are reported as some other problem.**
Programs: 038, 039, 040, 044, 047, 051, 052, 202, 239.

```text
039-arrow-le.em:3:10: a condition compares values with `==`, not `=`
  if score =< 50 {
           ^
Write `==` to compare values. Put an assignment on its own line.
```

Following that help gives `score == < 50`. `=>` gets "expected `{` to open a block, found
`=>`"; `<>`, `===` and `=+` get "expected an expression, found ..."; `x mod 2` gets "expected
`)` to close this call"; `if "Bo" in names` gets "expected `{` to open a block, found in";
`x > 0 and < 10` gets "expected an expression, found <"; and `n!` (a Swift unwrap) gets
"`n!` is not defined". Altadmri & Brown's mistake L (`=>` for `>=`) is among the commonest.
**A good message** names the operator meant: "write `>=`", "write `<=`", "write `!=`",
"write `==`", "write `+=`", "write `%`", "write `names.contains?(\"Bo\")`", "write
`x > 0 and x < 10`, or `0 < x < 10`", "write `n.or(0)`".

**F8. `//` and `/* */` comments are reported as "expected an expression".**
Programs: 021, 022.

```text
021-slash-comment.em:2:1: expected an expression, found //
```

A Java or JavaScript habit at the very first line of many programs.
**A good message:** "Emerald comments start with `#`".

**F9. Curly quotes pasted from a document are reported as a bad name character.**
Program: 019. `print(“Hello”)` gives "this character cannot be used in a name"; the help
talks about emoji.
**A good message:** "this is a curly quote; strings use straight quotes, as in `"Hello"`".

**F10. Lambda and dictionary shapes from other languages get lambda-parser messages.**
Programs: 164, 185, 221, 225, 287, 288, 291; 289, 290 (help only).

```text
221-dict-curly.em:2:13: expected a lambda parameter, found a string
  var ages = {"Ava": 12, "Bo": 13}
```

`{}` for an empty dictionary gets the same. A `do { ... } while` loop gets "expected `=>`
after this lambda's parameters, found `+=`"; Kotlin's `{ print(it) }` gets the same shape;
Python `lambda x: x * 2` gets "expected the end of the line"; JavaScript `(x) => x * 2` gets
"expected `)`"; a `func(...)` expression gets "expected an expression, found func"; Ruby
`|n|` gets "this character does not belong here". Only the last points at the right place
with nothing wrong in it; none says what to write.
**A good message:** "a dictionary is written with square brackets: `["Ava": 12]`", "an
empty dictionary needs a type: `var counts: Dict[String, Int] = []`", "Emerald has no
`do ... while`; write `while` with the condition first", "a block names its value: `{ n =>
print(n) }`", "write a lambda as `{ x => x * 2 }`".

**F11. A C-style `for` loop is reported as a stray semicolon.**
Program: 165. `for (var i = 0; i < 5; i++)` gives "Emerald does not use semicolons. Remove
it." Removing them gives more errors, not a loop. Altadmri & Brown's mistake F.
**A good message:** "Emerald's `for` visits a range: write `for i in 0..<5`".

**F12. Other constructs that are reported as a nearby parse problem.**
Programs: 023, 078, 079, 080, 137, 143, 243, 280.

| Program | Diagnostic | Real mistake, and a good message |
| --- | --- | --- |
| 023 | "expected an expression, found else" | a statement between `}` and `else`: "`else` must come straight after the `if` block's `}`" |
| 078 | "expected `=` after `first`, found -" | `first-name`: "a name cannot contain `-`; use `first_name`" |
| 079 | "expected `=` after `high`, found a name" | `high score`: "a name cannot contain spaces; use `high_score`" |
| 080 | "this is not a valid number" | `2nd_place`: "a name cannot start with a digit" |
| 137 | "[E1001] `Int` is not defined" | `square(n: Int)`, a type in a call: "pass a value, as in `square(4)`; the type belongs in the declaration" |
| 143 | "expected `{` to open a block, found -" | `-> Int`: "a return type follows a colon: `func square(n: Int): Int`" |
| 243 | "expected the end of the line, found a name" | `new Point(1, 2)`: "Emerald has no `new`; write `Point(1, 2)`" |
| 280 | "`try` needs a `catch` or `finally`" (at the `try`, line 2) | `except` on line 6: "write `catch`, not `except`" |

`Int` "is not defined" (137) is also untrue: it is a type.

### Wrong place

**F13. A missing `)` is reported at the start of the next line.**
Programs: 003, 008.

```text
003-missing-close-paren-call.em:4:1: expected `)` to close this call, found a name
  print("bye")
  ^^^^^
```

The mistake is the end of line 3, `print("Hello, " + name`. The caret on line 4 points at
correct code. The missing-`}` messages already point at the opening brace ("this block is
never closed"); this one should too.
**A good message:** "this `(` on line 3 is never closed", with the caret on the `(` and the
line end.

**F14. A constructor's misplaced `super(...)` is reported at the constructor's header.**
Program: 263. "this constructor has to start with `super(...)`" points at line 7,
`constructor(name: String) {`, though `super(name)` is written, two lines down, after
`self.tricks = 0`.
**A good message** points at `super(name)` on line 9 and says "move `super(name)` to the
constructor's first line, before `self.tricks = 0`". (178, in F3, is the other place miss.)

### A help that does not fix it

**F15. No close-spelling suggestion for any name, field or method.**
Programs: 057, 058, 059, 060, 061, 197, 251, 252, 302.

```text
058-wrong-case-variable.em:3:7: [E1001] `username` is not defined
  print(username)
        ^^^^^^^^
Check the spelling, or declare it before this line.
```

Rewrite-context 17.2: "Suggest close spellings for names, methods, types, and annotations."
None of `totl` (for `total`), `username` (`userName`), `pritn` and `Print` (`print`),
`calcualte_total`, `apend` (`append`), `nmae` (`name`), or `math` (`Math`) gets one. There is
no edit-distance search anywhere in `src/Checker.zig`; the only suggestions come from the
hand-written table of other languages' member names (`reportUnknownMember`). Kohn 2019 finds
misspelled names the most common Python novice error.
**A good message** adds "Did you mean `total`?" when one name in scope is a small edit away.

**F16. Other languages' built-in functions and values get only the generic "not defined".**
Programs: 086, 087, 089, 103, 104, 105, 106, 166, 167, 188, 190, 194, 213, 214, 294, 295, 297,
298, 303, 304, 305, 306, 307, 311, 312; member-table gaps 204, 218, 229, 299, 308, 309.

`names.length` gets "Emerald calls this `count`", but `len(names)` gets "`len` is not
defined. Check the spelling". The same generic help comes for `int(...)`, `str(...)`,
`parseInt`, `range(5)`, `sum`, `max`, `round`, `sqrt`, `type`, `True`, `null`, `None`, `nil`,
`console.log`, `System.out.println`, `printf`, `puts`, `println`, and `echo`. `random.randint`
(304) is worse: "`random` is built in, and built-in functions cannot be used as values". The
member table also misses `isEmpty` (for `empty?`), `containsKey` (`contains_key?`),
`toUpperCase` (`upper`, though Ruby's `upcase` is mapped), `join` (on the separator),
`format`, and `charAt`.
**A good message** says what Emerald writes: "`len(names)` is `names.count`", "`int(text)`
is `text.to_int()`", "`range(5)` is `0..<5`", "`True` is written `true`", "Emerald writes
absence as `nothing`", "`console.log` is `print`", "`sqrt(x)` is `x.square_root()`",
"`random.randint(1, 6)` is `random(1..6)`".

**F17. String-and-number help points the wrong way when the String should be a number.**
Programs: 083, 084, 085, 220, 277.

```text
083-input-as-number.em:3:7: `+` joins two Strings, but this is String and Int
  print(age + 1)
        ^^^^^^^
Convert the value with `to_string()`, or use interpolation, as in `"#{name}: #{score}"`.
```

Following it as `age + 1.to_string()` checks clean and prints `201` for an input of `20`.
Applying `to_string()` to `age` instead gives "String has no method `to_string`". The comparison
cases (`if age >= 18`, `if answer == 4`, `when 1` on a `String` subject) say only that the
types differ. Reading a number with `input` is the most common way a beginner meets this
(Kohn 2019).
**A good message**, when the String side came from `input`, `split` or a String binding and
the other side is a number: "`age` is text; convert it with `age.to_int()` to do
arithmetic".

**F18. A type that does not exist gets "declare the struct in this project".**
Programs: 099, 100, 101, 102, 144, 283.

```text
099-lowercase-type-int.em:2:12: `int` is not a type
  var count: int = 5
Check the spelling or declare the struct in this project.
```

This comes for `int`, `string`, `str`, `boolean`, `void`, and `catch error: ValueError`. No
student meant to declare a struct; each meant a built-in type. "Struct" is also a word the
introductory surface has not taught yet (it fails plain words).
**A good message:** "did you mean `Int`?"; for `void`, "leave the return type out, or write
`Nothing`"; for `ValueError`, "the error `to_int` raises is `RuntimeError`".

**F19. Optional-related helps that do not fix the mistake.**
Programs: 107, 125, 233, 236, 237.

| Program | Help | Problem with it |
| --- | --- | --- |
| 236 `if n > 3` with `n: Int?` | "Only numbers and Strings are ordered. Use `==` or `!=` to compare other values." | `n` is a number that may be missing; the fix is `n.or(0) > 3` or a `!= nothing` check, as 231 already says |
| 237 `square(n)` with `n: Int?` | "Pass a value of the expected type, or convert it first." | same: should offer `.or(0)` or a check |
| 233 `user?.address.city` | "Give it a fallback with `.or(...)`..." | the types guide says "write the second `?.`" |
| 125 `if found` with `found: Int?` | "Compare it to something, as in `count > 0`." | `found > 0` is the 236 error; should say `found != nothing` |
| 107 `var name: String = nothing` | "Give the declaration the type of its value" | gives `var name: Nothing`; should say `String?` |

**F20. Operator helps with nothing to write in place.**
Programs: 036, 045, 046, 108, 111, 116, 129, 207.

`a & b` and `side ^ 2` get "this character does not belong here. Remove it, or check for a
typo nearby"; `"-" * 20` gets "Strings have no arithmetic"; `word - "!"` the same; `"%s" %
name` the same; `scores + 3` (a list and an element) gets "Arithmetic works on Int and
Float"; `choice == 1 or 2` gets "Compare it to something, as in `count > 0`";
`add(2, 3) + 1` where `add` prints rather than returns gets "Arithmetic works on Int and
Float".
**A good message** names the replacement: "`and`", "`**`", "`"-".repeat(20)`",
"`word.remove_suffix("!")`", "`"Hello #{name}"`", "`scores.append(3)`", "`choice == 1 or
choice == 2`", "`add` gives back nothing because it has no `return`; return `a + b` instead of
printing it".

**F21. A keyword used as a name is not called a keyword.**
Programs: 074, 075, 076. `var class = "7B"` gives "expected a name after `var`, found class.
A declaration introduces one name, as in `var score = 0`." The student did write one name.
Altadmri & Brown's mistake H.
**A good message:** "`class` is one of Emerald's reserved words, so it cannot be a name;
try `class_name`".

**F22. Helps that, followed literally, lead to a new error that is not the next real problem.**
Programs: 028, 050, 142, 153, 192, 193, 211, 227, 244, 258, 259, 272, 284, 292.

| Program | Help, and what following it gives |
| --- | --- |
| 192, 193 `.size()`, `.length()` | "Emerald calls this `count`." → `names.count()` → "`count` is a property, so it takes no parentheses" (the code comment in `reportUnknownMember` notes this) |
| 153 `print(x, end="")` | "Write `end: ...`" → "a named argument needs a function, method, or type called by its own name"; the fix is `write(x)` |
| 050 `"adult" if age >= 18 else "child"` | suggests a trailing `if` → "expected the end of the line, found else"; the fix is `if age >= 18 then "adult" else "child"` |
| 244 `Point.new(1, 2)` | suggests declaring `func Point.new()`; the fix is `Point(1, 2)` |
| 028 `else (x > 0) {` | "expected `{`" → removing `(x > 0)` silently changes the meaning; the fix is `else if` |
| 227 `for name, age in ages` | "Write what to loop over after `in`"; the fix is `for (name, age) in ages` |
| 142 `func square(Int n)` | "Every parameter needs an explicit type, as in `count: Int`" does not say to swap them |
| 211 `names.remove(0)` | "convert it first"; the fix is `remove_at(0)` |
| 258, 259 `class Dog(Animal)`, `implements Shape` | "a body is enclosed in braces"; the fix is `extends Animal`, `with Shape` |
| 272 `var c: Color = red` | "Check the spelling"; the fix is `Color.red` |
| 284 `raise BadScore(...)` with no base | "Raise an Error value, such as `Error(...)`"; the fix is `class BadScore extends Error` |
| 292 `break` in `each { }` | "A function cannot end the loop that called it"; there is no function in sight, and the fix is a `for` loop |

### Wording

**F23. "Lambda" in messages for code with no lambda in it.**
Programs: 185, 221, 225, 291 (see F10). A student who wrote `{"Ava": 12}` or `do { ... }`
reads "expected a lambda parameter". The guide does teach lambdas, but these students did not
write one, so the word explains nothing.
**A good message** describes what was written ("this `{` starts a block") or, better, the
fixes in F10.

**F24. "Cannot be used as values" contradicts the guide.**
Programs: 139, 304. `name.upper` gives "Call it, as in `.upper()`. Methods cannot be used as
values yet." The core guide says "omitting a method's call parentheses captures it the same
way". One of the two is wrong; the beginner meets the message and the guide side by side.
(The message itself is right for 139, which is why 139's other questions pass.)
**A good message** keeps "`upper` is a method, so it needs parentheses: `.upper()`" and
drops "cannot be used as values yet", or the guide is corrected.

**F25 (lowest). Comparing Floats with `==` is silent.**
Program: 114. `0.1 + 0.2 == 0.3` is `false` with no warning. Most languages leave this
silent, and 17.2 asks for scarce warnings, so this is listed for completeness rather than as a
recommendation; a warning on `==` between two Float expressions, at least one computed, would
be the place for it.

## Not findings

- Several helps are long, but read plainly. The runtime messages (index, overflow, division by
  zero, recursion, missing dictionary entry, failed `assert`) all pass.
- 024's guard form and 178's warning are the only warnings in the corpus; warnings are scarce,
  as 17.2 asks.
- The corpus treats only the first diagnostic. Cascades after it (17.2, "avoid cascades")
  were not judged; 016's three semicolon errors are one reported per line, which reads well.

## Every program

Problem, Place, Help and Words are the four questions. "none" means no diagnostic for a real
mistake. "by design" programs are not counted.

| # | Program | Stage | First diagnostic | Problem | Place | Help | Words | Finding |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 001 | missing-close-brace-if | check | this block is never closed | pass | pass | pass | pass |  |
| 002 | missing-close-brace-func | check | this block is never closed | pass | pass | pass | pass |  |
| 003 | missing-close-paren-call | check | expected `)` to close this call, found a name | pass | **fail** | pass | pass | F13 |
| 004 | extra-close-brace | check | this `}` does not close anything | pass | pass | pass | pass |  |
| 005 | mismatched-list-bracket | check | expected `]` to close this list, found ) | pass | pass | pass | pass |  |
| 006 | missing-close-quote | check | this string is never closed | pass | pass | pass | pass |  |
| 007 | missing-close-quote-in-print | check | this string is never closed | pass | pass | pass | pass |  |
| 008 | nested-paren-imbalance | check | expected `)` to close this group, found a name | pass | **fail** | pass | pass | F13 |
| 009 | missing-open-brace-if | check | expected `{` to open a block, found the end of the line | pass | pass | pass | pass |  |
| 010 | missing-open-brace-while | check | expected `{` to open a block, found the end of the line | pass | pass | pass | pass |  |
| 011 | python-colon-if | check | expected `{` to open a block, found : | pass | pass | pass | pass |  |
| 012 | python-colon-for | check | expected `{` to open a block, found : | pass | pass | pass | pass |  |
| 013 | python-colon-func | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 014 | no-braces-indent-only | check | expected `{` to open a block, found the end of the line | pass | pass | pass | pass |  |
| 015 | one-line-if-no-braces | check | expected `{` to open a block, found a name | pass | pass | pass | pass |  |
| 016 | semicolons-everywhere | check | Emerald does not use semicolons | pass | pass | pass | pass |  |
| 017 | semicolon-after-if | check | Emerald does not use semicolons | pass | pass | pass | pass |  |
| 018 | semicolon-after-func-header | check | Emerald does not use semicolons | pass | pass | pass | pass |  |
| 019 | curly-quotes | check | this character cannot be used in a name | **fail** | pass | **fail** | pass | F9 |
| 020 | single-quotes | run | (none: runs) | n/a | n/a | n/a | n/a | by design: single quotes are raw strings (rewrite-context 4) |
| 021 | slash-comment | check | expected an expression, found // | **fail** | pass | **fail** | pass | F8 |
| 022 | block-comment | check | expected an expression, found / | **fail** | pass | **fail** | pass | F8 |
| 023 | else-on-new-line-after-blank | check | expected an expression, found else | **fail** | pass | **fail** | pass | F12 |
| 024 | misleading-indent-after-if | run | (none: runs) | **none** | - | - | - | F4 |
| 025 | elif | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 026 | elsif | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 027 | elseif-one-word | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 028 | else-if-without-condition-braces | check | expected `{` to open a block, found ( | pass | pass | **fail** | pass | F22 |
| 029 | python-else-colon | check | expected `{` to open a block, found : | pass | pass | pass | pass |  |
| 030 | assign-in-if | check | a condition compares values with `==`, not `=` | pass | pass | pass | pass |  |
| 031 | assign-in-while | check | a condition compares values with `==`, not `=` | pass | pass | pass | pass |  |
| 032 | assign-in-ternary | check | a condition compares values with `==`, not `=` | pass | pass | pass | pass |  |
| 033 | double-equals-as-statement | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 034 | and-ampersand | check | `&&` is not an operator in Emerald | pass | pass | pass | pass |  |
| 035 | or-pipes | check | `\|\|` is not an operator in Emerald | pass | pass | pass | pass |  |
| 036 | single-ampersand | check | this character does not belong here | pass | pass | **fail** | pass | F20 |
| 037 | bang-not | check | `!` is not an operator in Emerald | pass | pass | pass | pass |  |
| 038 | arrow-ge | check | expected `{` to open a block, found => | **fail** | pass | **fail** | pass | F7 |
| 039 | arrow-le | check | a condition compares values with `==`, not `=` | **fail** | pass | **fail** | pass | F7 |
| 040 | not-equal-diamond | check | expected an expression, found > | **fail** | pass | **fail** | pass | F7 |
| 041 | plus-plus | check | `++` is not an operator in Emerald | pass | pass | pass | pass |  |
| 042 | pre-plus-plus | check | `++` is not an operator in Emerald | pass | pass | pass | pass |  |
| 043 | minus-minus | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 044 | equals-plus | check | expected an expression, found + | **fail** | pass | **fail** | pass | F7 |
| 045 | caret-power | check | this character does not belong here | pass | pass | **fail** | pass | F20 |
| 046 | or-shortcut-value | check | a condition must be a Bool, but this is Int | pass | pass | **fail** | pass | F20 |
| 047 | and-shortcut-compare | check | expected an expression, found < | **fail** | pass | **fail** | pass | F7 |
| 048 | not-precedence | run | (none: runs) | n/a | n/a | n/a | n/a | by design: `not` binds looser than `==`, so this means what was meant |
| 049 | ternary-question-colon | check | `? :` is not a conditional operator in Emerald | pass | pass | pass | pass |  |
| 050 | python-ternary | check | a declaration cannot have a trailing `if` | pass | pass | **fail** | pass | F22 |
| 051 | triple-equals | check | expected an expression, found = | **fail** | pass | **fail** | pass | F7 |
| 052 | modulo-word | check | expected `)` to close this call, found a name | **fail** | pass | **fail** | pass | F7 |
| 053 | let-binding | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 054 | java-typed-decl | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 055 | no-var-assign | check | [E1001] `total` is not defined | pass | pass | pass | pass |  |
| 056 | use-before-declare | check | `score` is not declared until later in the file | pass | pass | pass | pass |  |
| 057 | misspelled-variable | check | [E1001] `totl` is not defined | pass | pass | **fail** | pass | F15 |
| 058 | wrong-case-variable | check | [E1001] `username` is not defined | pass | pass | **fail** | pass | F15 |
| 059 | misspelled-function | check | [E1001] `pritn` is not defined | pass | pass | **fail** | pass | F15 |
| 060 | capital-print | check | [E1001] `Print` is not defined | pass | pass | **fail** | pass | F15 |
| 061 | misspelled-user-function | check | [E1001] `calcualte_total` is not defined | pass | pass | **fail** | pass | F15 |
| 062 | misspelled-keyword-func | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 063 | misspelled-keyword-return | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 064 | misspelled-keyword-while | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 065 | const-reassign | check | [E3001] `limit` cannot be reassigned | pass | pass | pass | pass |  |
| 066 | const-compound | check | [E3001] `count` cannot be reassigned | pass | pass | pass | pass |  |
| 067 | const-list-append | check | [E3001] `names` is a `const`, so its contents cannot change | pass | pass | pass | pass |  |
| 068 | const-without-value | check | `answer` is a `const`, so it needs a value where it is declared | pass | pass | pass | pass |  |
| 069 | var-no-type-no-value | check | expected `=` after `result`, found the end of the line | pass | pass | pass | pass |  |
| 070 | read-before-assign-branch | check | `grade` may not have been assigned | pass | pass | pass | pass |  |
| 071 | redeclare-same-scope | check | `count` is already declared | pass | pass | pass | pass |  |
| 072 | shadow-in-loop-reset | check | `total` is already declared | pass | pass | pass | pass |  |
| 073 | shadow-param | check | `n` is already declared | pass | pass | pass | pass |  |
| 074 | keyword-as-name-class | check | expected a name after `var`, found class | pass | pass | **fail** | pass | F21 |
| 075 | keyword-as-name-in | check | expected a name after `var`, found in | pass | pass | **fail** | pass | F21 |
| 076 | keyword-as-param-name | check | expected a parameter name, found when | pass | pass | **fail** | pass | F21 |
| 077 | shadow-builtin-print | check | warning: `print` hides Emerald's built-in `print` | pass | pass | pass | pass |  |
| 078 | hyphen-in-name | check | expected `=` after `first`, found - | **fail** | pass | **fail** | pass | F12 |
| 079 | space-in-name | check | expected `=` after `high`, found a name | **fail** | pass | **fail** | pass | F12 |
| 080 | digit-start-name | check | this is not a valid number | **fail** | pass | **fail** | pass | F12 |
| 081 | string-plus-int | check | `+` joins two Strings, but this is String and Int | pass | pass | pass | pass |  |
| 082 | int-plus-string | check | `+` joins two Strings, but this is Int and String | pass | pass | pass | pass |  |
| 083 | input-as-number | check | `+` joins two Strings, but this is String and Int | pass | pass | **fail** | pass | F17 |
| 084 | input-compare-int | check | String and Int cannot be compared | pass | pass | **fail** | pass | F17 |
| 085 | string-equals-int | check | String and Int cannot be compared | pass | pass | **fail** | pass | F17 |
| 086 | python-int-call | check | [E1001] `int` is not defined | pass | pass | **fail** | pass | F16 |
| 087 | python-str-call | check | [E1001] `str` is not defined | pass | pass | **fail** | pass | F16 |
| 088 | java-to-string | check | [E4001] Int has no method `toString` | pass | pass | pass | pass |  |
| 089 | parse-int-js | check | [E1001] `parseInt` is not defined | pass | pass | **fail** | pass | F16 |
| 090 | to-int-runtime-bad | run | runtime: twelve is not a whole number | pass | pass | pass | pass |  |
| 091 | to-int-on-decimal | run | runtime: 3.50 is not a whole number | pass | pass | pass | pass |  |
| 092 | int-from-divide | check | [E2001] this is Float, but `average` was declared as Int | pass | pass | pass | pass |  |
| 093 | float-index | check | an index must be an Int, but this is Float | pass | pass | pass | pass |  |
| 094 | float-range-bound | check | counting works with whole numbers, but this is Float | pass | pass | pass | pass |  |
| 095 | float-to-int-param | check | this is Float, but parameter `count` of `stars` needs Int | pass | pass | pass | pass |  |
| 096 | int-annot-float-literal | check | [E2001] this is Float, but `price` was declared as Int | pass | pass | pass | pass |  |
| 097 | string-annot-int | check | [E2001] this is Int, but `name` was declared as String | pass | pass | pass | pass |  |
| 098 | int-annot-string | check | [E2001] this is String, but `count` was declared as Int | pass | pass | pass | pass |  |
| 099 | lowercase-type-int | check | `int` is not a type | pass | pass | **fail** | **fail** | F18 |
| 100 | lowercase-type-string | check | `string` is not a type | pass | pass | **fail** | **fail** | F18 |
| 101 | str-type-name | check | `str` is not a type | pass | pass | **fail** | **fail** | F18 |
| 102 | boolean-type-name | check | `boolean` is not a type | pass | pass | **fail** | **fail** | F18 |
| 103 | capital-true | check | [E1001] `True` is not defined | pass | pass | **fail** | pass | F16 |
| 104 | null-literal | check | [E1001] `null` is not defined | pass | pass | **fail** | pass | F16 |
| 105 | none-literal | check | [E1001] `None` is not defined | pass | pass | **fail** | pass | F16 |
| 106 | nil-literal | check | [E1001] `nil` is not defined | pass | pass | **fail** | pass | F16 |
| 107 | nothing-into-non-optional | check | [E2001] this is Nothing, but `name` was declared as String | pass | pass | **fail** | pass | F19 |
| 108 | string-times-int | check | multiplication needs numbers, but this is String and Int | pass | pass | **fail** | pass | F20 |
| 109 | string-index-assign | check | a String cannot be changed in place | pass | pass | pass | pass |  |
| 110 | char-single-quote-compare | run | (none: runs) | n/a | n/a | n/a | n/a | by design: single quotes are raw strings |
| 111 | string-minus | check | subtraction needs numbers, but this is String and String | pass | pass | **fail** | pass | F20 |
| 112 | int-overflow | run | runtime: multiplication of 2432902008176640000 and 21 overflows Int | pass | pass | pass | pass |  |
| 113 | divide-by-zero | run | runtime: floor division by zero | pass | pass | pass | pass |  |
| 114 | float-equality | run | (none: runs) | **none** | - | - | - | F25 |
| 115 | compound-divide-int | check | `/` produces Float, which `half` cannot hold because it is Int | pass | pass | pass | pass |  |
| 116 | percent-format | check | remainder needs numbers, but this is String and String | pass | pass | **fail** | pass | F20 |
| 117 | f-string | check | expected `)` to close this call, found a string | **fail** | pass | **fail** | pass | F5 |
| 118 | js-template | run | (none: runs) | **none** | - | - | - | F5 |
| 119 | python-braces-interp | run | (none: runs) | **none** | - | - | - | F5 |
| 120 | unterminated-interp | check | this `#{` is never closed | pass | pass | pass | pass |  |
| 121 | bool-string-compare | check | Bool and String cannot be compared | pass | pass | pass | pass |  |
| 122 | int-truthiness | check | a condition must be a Bool, but this is Int | pass | pass | pass | pass |  |
| 123 | string-truthiness | check | a condition must be a Bool, but this is String | pass | pass | pass | pass |  |
| 124 | list-truthiness | check | a condition must be a Bool, but this is List[Int] | pass | pass | pass | pass |  |
| 125 | optional-truthiness | check | a condition must be a Bool, but this is Int? | pass | pass | **fail** | pass | F19 |
| 126 | missing-return | check | not every path in `square` returns a value | pass | pass | pass | pass |  |
| 127 | missing-return-one-branch | check | not every path in `sign` returns a value | pass | pass | pass | pass |  |
| 128 | implicit-last-expression | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 129 | print-instead-of-return | check | addition needs numbers, but this is Nothing and Int | pass | pass | **fail** | pass | F20 |
| 130 | return-value-from-nothing | check | this function returns Nothing, so `return` cannot produce a value | pass | pass | pass | pass |  |
| 131 | return-wrong-type | check | this is String, but the function returns Int | pass | pass | pass | pass |  |
| 132 | result-into-wrong-type | check | [E2001] this is String, but `n` was declared as Int | pass | pass | pass | pass |  |
| 133 | too-few-args | check | `area` takes 2 arguments, but this call passes 1 | pass | pass | pass | pass |  |
| 134 | too-many-args | check | `greet` takes 1 argument, but this call passes 2 | pass | pass | pass | pass |  |
| 135 | wrong-arg-type | check | this is String, but parameter `n` of `square` needs Int | pass | pass | pass | pass |  |
| 136 | args-swapped | check | this is Int, but parameter `word` of `repeat_word` needs String | pass | pass | pass | pass |  |
| 137 | types-in-call | check | [E1001] `Int` is not defined | **fail** | pass | **fail** | pass | F12 |
| 138 | call-without-parens | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 139 | method-without-parens | check | `upper` is a method, so it needs parentheses | pass | pass | pass | **fail** | F24 |
| 140 | property-with-parens | check | `count` is a property, so it takes no parentheses | pass | pass | pass | pass |  |
| 141 | param-no-type | check | expected `:` and a type after `name`, found ) | pass | pass | pass | pass |  |
| 142 | param-type-first | check | expected `:` and a type after `Int`, found a name | pass | pass | **fail** | pass | F22 |
| 143 | arrow-return-type | check | expected `{` to open a block, found - | **fail** | pass | **fail** | pass | F12 |
| 144 | void-return-type | check | `void` is not a type | pass | pass | **fail** | **fail** | F18 |
| 145 | function-keyword | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 146 | def-keyword-braces | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 147 | fn-keyword | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 148 | modify-parameter | check | `n` cannot be reassigned | pass | pass | pass | pass |  |
| 149 | append-to-parameter | check | `scores` is a parameter, so a change to it would be lost when the function returns | pass | pass | pass | pass |  |
| 150 | default-before-required | check | `name` has no default, so it cannot follow `greeting`, which has one | pass | pass | pass | pass |  |
| 151 | named-arg-typo | check | `greet` has no parameter named `tims` | pass | pass | pass | pass |  |
| 152 | python-kwarg-equals | check | a named argument is written with `:` | pass | pass | pass | pass |  |
| 153 | print-end-kwarg | check | a named argument is written with `:` | pass | pass | **fail** | pass | F22 |
| 154 | call-int-as-function | check | `total` is Int, which is not a function | pass | pass | pass | pass |  |
| 155 | return-in-top-level-value | check | a top-level `return` cannot return a value | pass | pass | pass | pass |  |
| 156 | recursion-no-base-case | run | runtime: RecursionError: too much recursion calling `count_down` | pass | pass | pass | pass |  |
| 157 | ignored-result-trim | run | (none: runs) | **none** | - | - | - | F2 |
| 158 | ignored-result-sort | run | (none: runs) | **none** | - | - | - | F2 |
| 159 | ignored-result-upper | run | (none: runs) | **none** | - | - | - | F2 |
| 160 | ignored-result-own-func | run | (none: runs) | **none** | - | - | - | F2 |
| 161 | print-nothing-result | run | (none: runs) | **none** | - | - | - | F6 |
| 162 | func-after-use | run | (none: runs) | n/a | n/a | n/a | n/a | by design: control: functions may be called above their declaration |
| 163 | return-unreachable | check | warning: this code can never run | pass | pass | pass | pass |  |
| 164 | nested-func-def-in-if | check | expected an expression, found func | **fail** | pass | **fail** | pass | F10 |
| 165 | c-style-for | check | Emerald does not use semicolons | **fail** | pass | **fail** | pass | F11 |
| 166 | python-range | check | [E1001] `range` is not defined | pass | pass | **fail** | pass | F16 |
| 167 | python-range-two | check | [E1001] `range` is not defined | pass | pass | **fail** | pass | F16 |
| 168 | for-paren-in | check | expected a name after `for`, found ( | pass | pass | pass | pass |  |
| 169 | for-of | check | expected `in` after `name`, found a name | pass | pass | pass | pass |  |
| 170 | foreach-keyword | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 171 | for-over-int | check | a `for` loop cannot visit Int | pass | pass | pass | pass |  |
| 172 | off-by-one-inclusive | run | runtime: index 3 is outside this list, which has 3 elements | pass | pass | pass | pass |  |
| 173 | off-by-one-index | run | runtime: index 3 is outside this list, which has 3 elements | pass | pass | pass | pass |  |
| 174 | negative-index | run | runtime: index -1 is outside this list, which has 3 elements | pass | pass | pass | pass |  |
| 175 | countdown-range | check | this range is empty, because ranges count upward | pass | pass | pass | pass |  |
| 176 | one-based-index | run | runtime: index 3 is outside this list, which has 3 elements | pass | pass | pass | pass |  |
| 177 | infinite-while-no-increment | run | (none: runs forever) | **none** | - | - | - | F3 |
| 178 | infinite-while-true | check | warning: this code can never run | **fail** | **fail** | pass | pass | F3 |
| 179 | infinite-wrong-direction | run | (none: runs forever) | **none** | - | - | - | F3 |
| 180 | break-outside-loop | check | `break` can only be used inside a loop | pass | pass | pass | pass |  |
| 181 | continue-outside-loop | check | `continue` can only be used inside a loop | pass | pass | pass | pass |  |
| 182 | loop-var-reassign | check | `i` cannot be reassigned | pass | pass | pass | pass |  |
| 183 | modify-list-while-iterating | run | (none: runs) | n/a | n/a | n/a | n/a | by design: a `for` loop visits a snapshot (collections guide) |
| 184 | while-semicolon-body | check | Emerald does not use semicolons | pass | pass | pass | pass |  |
| 185 | do-while | check | expected `=>` after this lambda's parameters, found += | **fail** | pass | **fail** | **fail** | F10, F23 |
| 186 | until-loop | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 187 | unless | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 188 | range-step-python | check | [E1001] `range` is not defined | pass | pass | **fail** | pass | F16 |
| 189 | while-assign-input | check | a condition compares values with `==`, not `=` | pass | pass | pass | pass |  |
| 190 | len-function | check | [E1001] `len` is not defined | pass | pass | **fail** | pass | F16 |
| 191 | length-property | check | [E4001] List[String] has no property `length` | pass | pass | pass | pass |  |
| 192 | size-method | check | [E4001] List[String] has no method `size` | pass | pass | **fail** | pass | F22 |
| 193 | string-length-method | check | [E4001] String has no method `length` | pass | pass | **fail** | pass | F22 |
| 194 | string-len | check | [E1001] `len` is not defined | pass | pass | **fail** | pass | F16 |
| 195 | push | check | [E4001] List[String] has no method `push` | pass | pass | pass | pass |  |
| 196 | add-method | check | [E4001] List[String] has no method `add` | pass | pass | pass | pass |  |
| 197 | misspelled-append | check | [E4001] List[String] has no method `apend` | pass | pass | **fail** | pass | F15 |
| 198 | pop | check | [E4001] List[Int] has no method `pop` | pass | pass | pass | pass |  |
| 199 | index-method | check | [E4001] List[String] has no method `index` | pass | pass | pass | pass |  |
| 200 | contains-no-question | check | [E4001] List[String] has no method `contains` | pass | pass | pass | pass |  |
| 201 | includes-js | check | [E4001] List[String] has no method `includes` | pass | pass | pass | pass |  |
| 202 | in-operator | check | expected `{` to open a block, found in | **fail** | pass | **fail** | pass | F7 |
| 203 | empty-no-question | check | [E4001] List[String] has no method `empty` | pass | pass | pass | pass |  |
| 204 | is-empty-java | check | [E4001] List[String] has no method `isEmpty` | pass | pass | **fail** | pass | F16 |
| 205 | empty-list-no-type | check | an empty list needs a type | pass | pass | pass | pass |  |
| 206 | mixed-list | check | this is String, but the list holds Int | pass | pass | pass | pass |  |
| 207 | list-plus-element | check | addition needs numbers, but this is List[Int] and Int | pass | pass | **fail** | pass | F20 |
| 208 | append-two | check | `append` takes 1 argument, but this call passes 2 | pass | pass | pass | pass |  |
| 209 | append-list-to-list | check | this is List[Int], but `append` needs Int | pass | pass | pass | pass |  |
| 210 | append-wrong-type | check | this is String, but `append` needs Int | pass | pass | pass | pass |  |
| 211 | remove-by-index | check | this is Int, but `remove` needs String | pass | pass | **fail** | pass | F22 |
| 212 | sort-bang-print | run | (none: runs) | **none** | - | - | - | F6 |
| 213 | sum-function | check | [E1001] `sum` is not defined | pass | pass | **fail** | pass | F16 |
| 214 | max-function | check | [E1001] `max` is not defined | pass | pass | **fail** | pass | F16 |
| 215 | list-index-string | check | an index must be an Int, but this is String | pass | pass | pass | pass |  |
| 216 | empty-list-first-plus | check | addition needs numbers, but this is Int? and Int | pass | pass | pass | pass |  |
| 217 | list-of-list-index | check | expected `]` to close this index, found , | pass | pass | pass | pass |  |
| 218 | join-on-separator | check | [E4001] String has no method `join` | pass | pass | **fail** | pass | F16 |
| 219 | split-no-arg | check | `split` takes 1 argument, but this call passes 0 | pass | pass | pass | pass |  |
| 220 | list-sum-strings | check | `+` joins two Strings, but this is Int and String | pass | pass | **fail** | pass | F17 |
| 221 | dict-curly | check | expected a lambda parameter, found a string | **fail** | pass | **fail** | **fail** | F10, F23 |
| 222 | dict-dot-access | check | [E4001] Dict[String, Int] has no property `Ava` | pass | pass | pass | pass |  |
| 223 | dict-lookup-arith | check | addition needs numbers, but this is Int? and Int | pass | pass | pass | pass |  |
| 224 | dict-get-python | check | [E4001] Dict[String, Int] has no method `get` | pass | pass | pass | pass |  |
| 225 | dict-empty-no-type | check | expected a lambda parameter, found } | **fail** | pass | **fail** | **fail** | F10, F23 |
| 226 | dict-duplicate-key | check | this key is already used above | pass | pass | pass | pass |  |
| 227 | dict-for-two-names | check | expected `in` after `name`, found , | pass | pass | **fail** | pass | F22 |
| 228 | dict-items-call | check | [E4001] Dict[String, Int] has no method `items` | pass | pass | pass | pass |  |
| 229 | dict-has-key | check | [E4001] Dict[String, Int] has no method `containsKey` | pass | pass | **fail** | pass | F16 |
| 230 | dict-count-plus-equals | run | runtime: there is no entry for "a" | pass | pass | pass | pass |  |
| 231 | maybe-plus-one | check | addition needs numbers, but this is Int? and Int | pass | pass | pass | pass |  |
| 232 | method-on-optional | check | this is String?, so `upper` may not be there to use | pass | pass | pass | pass |  |
| 233 | optional-chain-missing-second | check | this is Address?, so `city` may not be there to use | pass | pass | **fail** | pass | F19 |
| 234 | optional-chain-assign | check | this is User?, so there may be nothing to assign into | pass | pass | pass | pass |  |
| 235 | double-optional | check | a type cannot be optional twice | pass | pass | pass | pass |  |
| 236 | optional-compare-greater | check | `>` needs numbers, but these are Int? values | pass | pass | **fail** | pass | F19 |
| 237 | optional-to-param | check | this is Int?, but parameter `n` of `square` needs Int | pass | pass | **fail** | pass | F19 |
| 238 | optional-narrow-lost-reassign | check | addition needs numbers, but this is Int? and Int | pass | pass | pass | pass |  |
| 239 | optional-bang-unwrap | check | [E1001] `n!` is not defined | **fail** | pass | **fail** | pass | F7 |
| 240 | optional-or-wrong-type | check | this is String, but the value it stands in for is Int | pass | pass | pass | pass |  |
| 241 | elvis-operator | check | `??` is not an operator in Emerald | pass | pass | pass | pass |  |
| 242 | struct-missing-field | check | `Point` takes 2 arguments, but this call passes 1 | pass | pass | pass | pass |  |
| 243 | new-keyword | check | expected the end of the line, found a name | **fail** | pass | **fail** | pass | F12 |
| 244 | ruby-dot-new | check | `Point` has no type-level member named `new` | pass | pass | **fail** | pass | F22 |
| 245 | field-no-type | check | expected `:` and a type after `x`, found the end of the line | pass | pass | pass | pass |  |
| 246 | ts-field-no-var | check | `name` needs `var` or `const` in front | pass | pass | pass | pass |  |
| 247 | method-no-self | check | `width` is a member of `Rect`, so it is reached through `self` | pass | pass | pass | pass |  |
| 248 | this-instead-of-self | check | Emerald calls the current value `self` | pass | pass | pass | pass |  |
| 249 | python-self-param | check | `self` is not listed as a parameter | pass | pass | pass | pass |  |
| 250 | python-init | run | (none: runs) | n/a | n/a | n/a | n/a | by design: `__init__` is an ordinary method; the generated constructor does the work |
| 251 | unknown-field | check | Point has no field named `z` | pass | pass | **fail** | pass | F15 |
| 252 | misspelled-field | check | Pet has no field named `nmae` | pass | pass | **fail** | pass | F15 |
| 253 | const-struct-field | check | [E3001] `p` is a `const`, so its contents cannot change | pass | pass | pass | pass |  |
| 254 | const-field-assign | check | `title` is a `const` field of Book, so it cannot change | pass | pass | pass | pass |  |
| 255 | struct-change-without-bang | check | [E3001] `c` is a `const`, so its contents cannot change | pass | pass | pass | pass |  |
| 256 | instance-method-on-type | check | `speak` belongs to each `Dog` value, not to the type | pass | pass | pass | pass |  |
| 257 | missing-override | check | `speak` is already a method of `Animal` | pass | pass | pass | pass |  |
| 258 | python-inherit-parens | check | expected `{` after `Dog`, found ( | pass | pass | **fail** | pass | F22 |
| 259 | java-implements | check | expected `{` after `Square`, found a name | pass | pass | **fail** | pass | F22 |
| 260 | trait-member-missing | check | `Square` does not supply `area`, which the trait `Shape` requires | pass | pass | pass | pass |  |
| 261 | private-access | check | `_balance` is private to `Account` | pass | pass | pass | pass |  |
| 262 | construct-abstract | check | `Shape` is abstract, so it cannot be constructed | pass | pass | pass | pass |  |
| 263 | super-not-first | check | this constructor has to start with `super(...)`, because building `Animal` takes arguments | pass | **fail** | pass | pass | F14 |
| 264 | struct-extends | check | a struct cannot extend another type | pass | pass | pass | pass |  |
| 265 | java-object-decl | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 266 | method-outside-type | check | `self` is only available inside a constructor or a method | pass | pass | pass | pass |  |
| 267 | struct-equality-class | run | (none: runs) | n/a | n/a | n/a | n/a | by design: class equality is identity, as documented |
| 268 | struct-copy-surprise | run | (none: runs) | n/a | n/a | n/a | n/a | by design: struct copies are independent, as documented |
| 269 | switch-statement | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 270 | case-colon | check | expected a block or `then` after what this arm matches, found : | pass | pass | pass | pass |  |
| 271 | case-default | check | expected `when` or `else` in this `case`, found a name | pass | pass | pass | pass |  |
| 272 | enum-bare-value | check | [E1001] `red` is not defined | pass | pass | **fail** | pass | F22 |
| 273 | enum-misspelled | check | `Color` has no value or type-level member named `gren` | pass | pass | pass | pass |  |
| 274 | case-then-nonexhaustive | check | this `case` gives no value for `Color.blue` | pass | pass | pass | pass |  |
| 275 | case-statement-nonexhaustive | check | warning: this `case` does not cover `Color.blue` | pass | pass | pass | pass |  |
| 276 | enum-capital-value | check | `Color` has no value or type-level member named `RED` | pass | pass | pass | pass |  |
| 277 | case-when-string-vs-int | check | `when` compares this with the subject by `==`, but String and Int cannot be compared | pass | pass | **fail** | pass | F17 |
| 278 | throw-keyword | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 279 | raise-string | check | only an Error can be raised, but this is String | pass | pass | pass | pass |  |
| 280 | except-keyword | check | `try` needs a `catch` or `finally` | **fail** | **fail** | pass | pass | F12 |
| 281 | catch-js-parens | check | expected a name after `catch` | pass | pass | pass | pass |  |
| 282 | try-without-catch | check | `try` needs a `catch` or `finally` | pass | pass | pass | pass |  |
| 283 | catch-unknown-type | check | `ValueError` is not a type | pass | pass | **fail** | **fail** | F18 |
| 284 | error-subclass-no-extends | check | only an Error can be raised, but this is BadScore | pass | pass | **fail** | pass | F22 |
| 285 | assert-assign | check | a condition compares values with `==`, not `=` | pass | pass | pass | pass |  |
| 286 | assert-fails | run | runtime: AssertionError: assertion failed: `total == 4` | pass | pass | pass | pass |  |
| 287 | python-lambda | check | expected the end of the line, found a name | **fail** | pass | **fail** | pass | F10 |
| 288 | js-arrow-parens | check | expected `)` to close this call, found => | **fail** | pass | **fail** | pass | F10 |
| 289 | ruby-block-pipes | check | this character does not belong here | pass | pass | **fail** | pass | F10 |
| 290 | ruby-do-end | check | this character does not belong here | pass | pass | **fail** | pass | F10 |
| 291 | kotlin-it | check | expected `=>` after this lambda's parameters, found ( | **fail** | pass | **fail** | **fail** | F10, F23 |
| 292 | break-in-each | check | `break` can only be used inside a loop | pass | pass | **fail** | pass | F22 |
| 293 | block-wrong-arity | check | this lambda takes 2 values, but it will be given 1 | pass | pass | pass | pass |  |
| 294 | console-log | check | [E1001] `console` is not defined | pass | pass | **fail** | pass | F16 |
| 295 | system-out-println | check | [E1001] `System` is not defined | pass | pass | **fail** | pass | F16 |
| 296 | python2-print | check | this result is never used | **fail** | pass | **fail** | pass | F1 |
| 297 | printf | check | [E1001] `printf` is not defined | pass | pass | **fail** | pass | F16 |
| 298 | puts | check | [E1001] `puts` is not defined | pass | pass | **fail** | pass | F16 |
| 299 | to-upper-case | check | [E4001] String has no method `toUpperCase` | pass | pass | **fail** | pass | F16 |
| 300 | ruby-upcase | check | [E4001] String has no property `upcase` | pass | pass | pass | pass |  |
| 301 | string-contains-no-q | check | [E4001] String has no method `contains` | pass | pass | pass | pass |  |
| 302 | math-sqrt-lower | check | [E1001] `math` is not defined | pass | pass | **fail** | pass | F15 |
| 303 | sqrt-bare | check | [E1001] `sqrt` is not defined | pass | pass | **fail** | pass | F16 |
| 304 | python-random-randint | check | `random` is built in, and built-in functions cannot be used as values | **fail** | pass | **fail** | **fail** | F16, F24 |
| 305 | type-function | check | [E1001] `type` is not defined | pass | pass | **fail** | pass | F16 |
| 306 | round-function | check | [E1001] `round` is not defined | pass | pass | **fail** | pass | F16 |
| 307 | input-int-python | check | [E1001] `int` is not defined | pass | pass | **fail** | pass | F16 |
| 308 | string-format-method | check | [E4001] String has no method `format` | pass | pass | **fail** | pass | F16 |
| 309 | char-at | check | [E4001] String has no method `charAt` | pass | pass | **fail** | pass | F16 |
| 310 | string-index-out-of-range | run | runtime: index 2 is outside this String, which has 2 characters | pass | pass | pass | pass |  |
| 311 | println-swift | check | [E1001] `println` is not defined | pass | pass | **fail** | pass | F16 |
| 312 | echo | check | [E1001] `echo` is not defined | pass | pass | **fail** | pass | F16 |
| 313 | control-greeter | run | (none: runs) | n/a | n/a | n/a | n/a | by design: control |
| 314 | control-loop | run | (none: runs) | n/a | n/a | n/a | n/a | by design: control |
