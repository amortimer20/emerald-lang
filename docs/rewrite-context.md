# Emerald rewrite context

Status: single working design baseline for the Zig rewrite.

This is the only rewrite context document. It exists so Emerald does not depend on
conversational memory. It consolidates the complete exported rewrite discussion, its
decision ledger and sanity-check audit, and deliberate changes from the .NET prototype.
Historical prototype experiments and design notes do not override this document.

The labels used here are:

- **Settled** — use this rule when designing and implementing the rewrite.
- **Deferred** — preserve room for it but do not implement it initially.
- **Provisional** — a reversible choice made to keep progress possible. Revisit only when
  code or teaching experience supplies evidence.

## Contents

1. Position
2. A first program
3. Source text and names
4. Values and types
5. Expressions and operators
6. Statements and control flow
7. Functions and callable values
8. Collections and compound values
9. Strings and numbers
10. Structs, classes, and members
11. Traits and operators
12. Enums and branching
13. Errors and resources
14. Program and project structure
15. Standard library organization
16. Annotations, assertions, and tests
17. Diagnostics
18. Command-line and editor tooling
19. Zig implementation architecture
20. Implementation sequence
21. Deferred features
22. Reconstruction decisions and history
23. Consistency rules for future work
24. Evidence-driven roadmap
25. Definition of ready for implementation

## 1. Position

Emerald is a statically typed, inferred, garbage-collected programming language intended
to be approachable as a first language and enjoyable after the introductory course ends.
It borrows Ruby's delight in expressive libraries, Python's readable surface, C#'s useful
distinction between value and reference types, and traits as a composition mechanism.

The governing principles are settled:

1. A beginner should be able to explain every character in an introductory program.
2. Static checking should prevent mistakes and teach the correction.
3. Expressiveness belongs in regular, discoverable language and library features rather
   than runtime magic.
4. The core syntax stays small while the standard library may be rich.
5. The implementation host must adapt to Emerald. Emerald must not distort itself around
   Zig, .NET, or a future backend.
6. Optionals and generics grow only from demonstrated needs. They are not general-purpose
   escape hatches for library implementation.
7. Reversible choices may begin simply. Irreversible surface area needs evidence.
8. Errors are pedagogy: wording, locations, examples, and recovery suggestions are part of
   the product.

Emerald is experimental. Compatibility is valuable once users depend on a release, but
the pre-1.0 language may remove ideas that do not survive real programs.

## 2. A first program

The introductory surface is settled:

```emerald
var name = input("What is your name? ")
print("Hello, #{name}!")
```

There is no class wrapper, `public`, `static`, `void`, namespace declaration, manifest, or
import in the first program. `input`, `print`, and `write` are prelude functions callable
without qualification.

```emerald
print("This includes a newline.")
write("This does not. ")
write("The next text stays on this line.")
```

`input(prompt)` writes the optional prompt, reads one line, removes its line ending, and
returns a `String`. End of input raises `InputError`. The settled
`input_maybe(prompt)` alternative returns an optional `String` and produces `nothing` at
end of input.

## 3. Source text and names

### 3.1 Files and encoding

- Source files use the `.em` extension.
- Source is UTF-8. Unix and Windows line endings and an optional UTF-8 byte-order mark are
  accepted. Malformed input is reported at the offending byte span. The formatter writes
  UTF-8 without a byte-order mark and uses one consistent line-ending style.
- Newlines terminate ordinary statements. They are ignored while parentheses or brackets
  remain open and after a token that cannot end an expression, including a binary
  operator, comma, or member dot. Expression-position collection literals follow the same
  rule; statement blocks retain normal newline termination, including a block or `case`
  written inside parentheses, whose braces restore it until they close. Continuation is determined
  from the preceding tokens rather than indentation, with one exception that looks at the
  next line: a line whose first token is a member dot, `.` or `?.`, continues the line
  before it. Blank lines and ordinary comments between them are skipped. There is no
  backslash continuation syntax.

The leading dot exists because method chaining is the pipeline notation (5.4), so long
chains are idiomatic and need to wrap, and a dot at the start of a line reads as "and
then" in a way a dot at the end of the previous one does not:

```emerald
var count = numbers
    .filter { number => number > 0 }
    .count
```

A line cannot otherwise begin with `.`, so the exception never changes the meaning of a
program that would have been valid without it. `..` is a range operator rather than a
member dot and does not continue a line.
- Semicolons are unnecessary and should not become a parallel statement syntax.

The grammar owns the exact continuation-token list, and lexer/parser conformance tests
cover every member of it.

### 3.2 Comments

The forms are settled:

```emerald
# A line comment

## Documentation for the declaration below.
func greet() {
    print("Hello")
}

#[
A block comment may span lines.
]#
```

Block comments nest. An unclosed block comment reports its opening `#[` rather than only
the end of the file.

`#`, `##`, and `#[` are distinguished by the next character rather than by counting an
arbitrary run of hashes. Documentation text is Markdown. The initial tag set is
deliberately empty: parameters, returns, and expected errors are described naturally in
prose until tooling demonstrates a need for structured tags. An orphaned `##` block
produces a warning because it does not describe a declaration.

An override or trait implementation uses its own documentation when present. Otherwise,
documentation tools inherit the text from the overridden declaration or satisfied trait
requirement and label its source. If several requirements contribute different text, the
tool presents each source rather than silently choosing one. Private helper documentation
does not become part of an adopter's public API.

### 3.3 Naming

The casing rules are settled:

| Declaration | Convention |
| --- | --- |
| Types and traits | `PascalCase` |
| Variables, fields, parameters | `snake_case` |
| Functions and methods | `snake_case` |
| Constants and enum values | `snake_case` |

Violations are style warnings rather than syntax errors. American English is the standard
library spelling convention: `Color`, `center`, and `initialize`.

Methods returning `Bool` conventionally end in `?`. Omitting the suffix from a Boolean
function produces a style warning; a name ending in `?` with a non-`Bool` result is a type
error. The compiler remains capable of describing an external API that cannot follow
Emerald's convention.

```emerald
func empty?(): Bool {
    return self.count == 0
}
```

A leading underscore marks a private member:

```emerald
var _cached_total = 0
```

There is no `private` keyword. `protected` is deferred.

Identifiers follow Unicode identifier rules with NFC normalization, are case-sensitive,
and exclude emoji. Canonically equivalent spellings denote the same name. Keywords remain
English; casing conventions apply only to writing systems that have case.

### 3.4 Braces and parentheses

Braces delimit blocks. Whitespace is not semantic — brace placement included, so the
grammar accepts a block's opening brace either trailing the line that introduces it
(Stroustrup) or starting its own line right after (Allman); a closing brace begins a line
either way, and `else`, `catch`, and `finally` begin their own lines under both styles.

```emerald
if score >= 10 {
    print("You win!")
}
else {
    print("Keep trying.")
}
```

```emerald
if score >= 10
{
    print("You win!")
}
else
{
    print("Keep trying.")
}
```

A project picks exactly one of the two as its canonical style, in `emerald.toml`'s
`brace_style` (`stroustrup`, the default, or `allman`); the formatter always normalizes
every file to that one choice, regardless of which style it was written in, so a project
still reads as one consistent style throughout — §18.3's "one canonical output" promise is
about a project having one answer, not about the language having only one legal way to
write a brace. An earlier draft made Stroustrup the only legal spelling anywhere, with no
per-project choice at all; it was reversed; see the decision table in section 22 for why.

Conditions conventionally omit parentheses:

```emerald
if ready?() {
    start()
}
```

Parentheses remain legal when they clarify grouping. A formatter must not remove grouping
that changes meaning.

Ordinary calls use parentheses, including zero-argument calls. A trailing lambda may serve
as the final argument without an empty `()` before it. Otherwise, a bare function or method
name obtains the callable value:

```emerald
player.greet()       # call
const greet = player.greet # bound method value
```

Braces appear only where a declared construct expects a block or where expression context
admits a lambda. A bare anonymous block is not a standalone scoping statement; use
a named function or an existing control-flow construct when a separate scope is needed.
Keywords remain reserved as names: a member is declared with an ordinary identifier, so
member declarations do not create a second identifier grammar. Reaching for a member is the
one exception. The name after a `.` may be a keyword, because nothing else can appear there
and so nothing is made ambiguous by allowing it. This is what lets 4.5 spell its fallback
`maybe.or(0)`, matching the `to_int_or` family, without `or` ceasing to be a keyword
everywhere else.

An implementation accepts at least 256 nested syntactic delimiters or declarations and
checks its nesting budget before consuming the host stack. Excess reports a normal source
diagnostic at the delimiter that crosses the documented limit. Programs must not depend
on a particular implementation accepting deeper pathological nesting.

## 4. Values and types

### 4.1 Static typing and inference

Every expression has a static type before execution. Local types are inferred when the
initializer determines one:

```emerald
var score = 0
var title = "Emerald"
```

An uninitialized variable is allowed only with an explicit type:

```emerald
var winner: Player
```

Reading it before definite assignment is an error. The checker proves definite assignment
through control flow rather than inserting a default value.

A `const` always has an initializer. It can never be assigned afterward, so `const limit:
Int` would stay unassigned forever, and is rejected where it is written.

```emerald
var message: String

if won?() {
    message = "You won"
}
else {
    message = "Try again"
}

print(message)
```

If any reachable branch leaves `message` unassigned, its later read fails during checking.

### 4.2 Initial built-in types

The initial semantic vocabulary is:

- `Bool`
- `Int`
- `Float`
- `String`
- `Nothing`
- list, dictionary, set, tuple, and range types
- functions
- user structs, classes, enums, and traits

`Int` and `Float` have settled widths. `Int` is a 64-bit signed two's-complement integer
with the inclusive range `-9223372036854775808` through `9223372036854775807`. `Float` is
IEEE-754 binary64. These are language semantics, not host details: every backend uses the
same widths, and the checked-overflow and conversion rules in 5.3 and 9.4 are defined
against exactly this range.

Arbitrary-precision integers were considered and rejected for the initial language. They
remove one class of beginner surprise but complicate hashing, the C boundary, and any
future native backend far more than checked overflow does. A clear overflow diagnostic is
the better teaching moment.

`Nothing` is the absence-only type. The value is written `nothing`.

```emerald
const missing: Nothing = nothing
```

An optional type is written with a trailing `?`:

```emerald
var result: Int? = "42".to_int_maybe()
var maybe_names: List[String]? = nothing
var names_that_may_be_absent: List[String?] = [nothing, "Ava"]
```

The postfix form is settled. It is the spelling C#, Swift, and Kotlin already use, and C# is
a language this design borrows from deliberately, so it arrives familiar to the people most
likely to teach Emerald. Structural placement stays legible: `List[String]?` is an optional list
and `List[String?]` is a list of optionals, matching the rule in 4.5.

`?` is a type constructor for this one relationship only. It is not a general generic
system: users cannot declare their own `?`-like type constructors, and a bracketed spelling
such as `OptionalList[Int]` was rejected precisely because it would invite that expectation.
Optionals do not make all references nullable.

**Lexical rule.** Because 3.3 lets an identifier end in `?`, the sequence `Int?` is
genuinely ambiguous to a lexer: maximal munch produces one identifier token `Int?` rather
than `Int` followed by an optional marker. Emerald resolves this in the parser, not the
lexer. The lexer keeps maximal munch and emits the single identifier token. In type
position — after `:`, inside `[...]`, or in a function type — the parser splits a trailing
`?` off an identifier token and treats it as the optional marker, adjusting the span by its
final byte.

The split is safe because optionality is only ever written in a type, never at a use site,
so no lexer lookahead or parser-to-lexer feedback is required. This must not be resolved by
consulting the casing conventions in 3.3, which are style warnings rather than enforced
rules; lexing must not depend on a convention a program is allowed to violate.

A declaration exercising both meanings of `?` in one line is a required conformance test:

```emerald
func valid?(input: Int?): Bool {
    return input != nothing
}
```

Here `valid?` keeps its `?` as part of the declared name, while the parameter type `Int?`
splits into an optional `Int`. A `?` name promises a plain `Bool` answer (3.3), so a
predicate never returns `Bool?`.

### 4.3 `var` and `const`

`var` permits rebinding; `const` does not:

```emerald
var score = 1
score = 2

const max_score = 100
```

`const` freezes a value. A `const` list, dictionary, set, tuple, or struct cannot change at
all: it can be neither replaced nor mutated in place. For a value type the two are the same
thing, since `players.append("Noah")` and `players = players + ["Noah"]` leave the same
observable result, so forbidding one while allowing the other would protect nothing.

A class instance is different. The binding holds a reference to a shared object, so `const`
fixes which object the binding refers to, while the object's own `var` fields may still
change through it. The rule stops at the first reference, which is exactly where sharing
begins. This is Swift's `let`.

```emerald
const players = ["Ava"]
players.append("Noah")    # error: `players` is a const list
players = ["Mia"]         # error

const window = Window()   # a class
window.title = "Emerald"  # allowed: the object is shared
window = Window()         # error
```

Mutating a struct includes calling one of its methods that assigns to a field of `self`,
directly or through another method. The checker determines which struct methods mutate
`self` from their bodies, so there is no `mutating` keyword. A diagnostic for mutating a
`const` suggests `var` when a changing copy is what was meant.

While a method that changes a struct runs, or a property's setter, the binding it was called
through belongs to that call. Reaching the same binding another way while the call is in progress — from a function
or block the method calls — is a runtime error rather than a view of a half-changed value.
This is what lets a changing method change a collection field where it lives instead of
copying it on every call. The call has the binding from the moment its arguments, defaults
included, have been evaluated, so an argument or a default may still read it. A default may
not change `self`.

If a changing method or setter raises after changing its receiver, the receiver is still
returned to its place and the changes already made remain visible. An error does not roll
back ordinary mutations; this is the same behavior as mutating a class object before an
error. Code that needs all-or-nothing behavior prepares a separate value and stores it only
after the operation succeeds.

Fields also use `var` and `const`. A `const` field is assigned during construction and is
not later rebound, and it freezes a value it holds under the same rule. A `var` field may
be updated by methods.

### 4.4 Type relationships and conversion

Conditions require `Bool`; values do not become truthy or falsey implicitly.

Numeric widening from `Int` to `Float` happens wherever a `Float` is expected: an
arithmetic operand beside a `Float`, a declaration or assignment to a `Float`, an argument
to a `Float` parameter, a returned value, and an element of a literal whose inferred
element type is `Float`. It is the only implicit conversion, and it always actually
converts, so `var rate: Float = 1` holds and prints `1.0`. Other conversions are explicit
and use descriptive method names:

```emerald
"42".to_int()
"42".to_int_or(0)
"42".to_int_maybe()
```

The three forms mean raise on failure, use a supplied fallback, or return an optional
`Int`.
Equivalent conversion families may be added only when the conversion itself belongs.

Mixed `Int`/`Float` comparisons compare their mathematical values without first rounding
the integer into `Float`. Widening a large `Int` to `Float` may lose precision, but that
loss must not make two distinct numeric values compare equal accidentally.

Mutable collection types are invariant: `List[Dog]` is not assignable to `List[Animal]`. A
literal's own elements widen more freely than that, the same way `[1, 2.5]` infers
`List[Float]`: a mixed list, dictionary, value-producing `case`, or inline `if` of sibling classes
(10.7) infers their nearest shared base — `[Dog(), Cat()]` infers `List[Animal]` with no
annotation needed, the same base an explicit `List[Animal]` already accepted them under.
Two classes that share only a trait, with no common base class, still need an explicit
common trait annotation; inferring across a shared trait is not attempted, since a value's
declared type would then expose only the trait's own contract (11.2) rather than either
class's own members, a real reduction of what a reader can immediately do with it, unlike
inferring to a base class the elements already were, at every field and method they had.

`is` tests a runtime type and narrows a name within the proven branch. Explicit casts use
normal control-flow narrowing; explicit downcast operators such as `as`, forced casts, and
optional casts are deferred.

Optional chaining uses `?.` for one nullable link: `user?.name` returns `String?`, and
`user?.greet(message)` returns that call's result as an optional. When the receiver is
`nothing`, the access or call returns `nothing` and call arguments are not evaluated. Each
nullable link is written explicitly (`user?.address?.street`); a plain `.` still needs a
present receiver. An optional chain is read-only: an assignment through `?.` is rejected at
check time, and so is a struct's changing method through `?.`, since `?.` only ever reads
the receiver's value and a struct's changing method needs a place to write its change back
into. A class's changing method is unaffected, since mutating its one shared object is
sound however it's reached.

An `is` test that static analysis can prove always true or false remains valid and produces
that result, but receives a warning (17.1) explaining the known result. The true warning
fires when the value's type here, narrowing included, is already exactly the target. The
false warning fires when both sides are classes with no inheritance relationship: no instance
can be both. It also fires for a class tested against a trait when neither that class nor any
declared subclass adopts the trait. The tested expression is still evaluated exactly once even
when its result is known. Tests through a base class or trait receive no warning when the
runtime value could genuinely have the target type. A trait-typed value, struct, or enum still
receives no false warning: its possible value set needs a separate analysis. No
binding-pattern extension to `is` is included initially.

Every value exposes a read-only `type_name` property using Emerald's source spelling for
its concrete runtime type:

```emerald
var animal: Animal = Dog()
print(animal.type_name)  # "Dog"
print([1, 2].type_name)  # "List[Int]"
```

This universal property does not imply that values inherit from a common `Object` class.
First-class type values and general reflection are deferred; programs use `is` for
type-dependent control flow. `type_name` is intended for learning, diagnostics, and
debugging rather than durable program identifiers.

`is` binds like a comparison and does not chain with one, so `not (value is Dog)` is how a
failed test is written, and `and` and `or` apply to the whole test. Its type has no `?`: a
present value never has one, and presence is tested against `nothing`. A test that holds
narrows a name the way a comparison with `nothing` does, to the tested type when that says
more: an optional's own type, or a class that extends the one the name has. The right side of
`and` is checked knowing its left side held, and the right side of `or` knowing its left side
failed, for both kinds of narrowing. `type_name` is reserved: no type may declare a member
with that name, and it cannot be assigned. A tuple's `type_name` and `is` look at the class
of each object it holds, since tuples widen position by position; a collection's use its
static type, since collections are invariant.

### 4.5 Optional handling

Optional behavior remains deliberately small:

```emerald
var number = text.to_int_maybe()
var usable = number.or(0)
```

Comparison with `nothing` narrows a stable local name:

```emerald
if number != nothing {
    print(number + 1)
}
```

Narrowing does not assume that a mutable property remains unchanged between reads. Binding
the property to a local makes the proof explicit.

A narrowed mutable binding loses that fact when it is reassigned or when a called closure
could reassign its captured binding. A module-level variable that any function, method,
constructor, or accessor assigns is not narrowed at all, since any call between the test
and the use could be that one. A block may run after the variables it captures are given
new values, so inside a block a captured variable that any assignment gives a new value
keeps its declared type, whatever a test outside the block proved; a test inside the block
still narrows it there. `const` bindings and read-only parameters retain
narrowing because they cannot be rebound. Overload selection uses the type known at the
call site after any such narrowing.

Optional chaining uses `?.`:

```emerald
var city = user?.address?.city.or("Unknown")
```

Each potentially absent link is written explicitly. An optional result does not make the
rest of the chain implicitly optional, so `user?.address.city` is rejected when `address`
may be absent; write the second `?.`. The completed chain still produces an optional value
that can be narrowed or handled with `.or(...)`.

Optional chaining is permitted for reads and calls. Assignment through a chain is
disallowed because `user?.name = "Ava"` hides whether the mutation happened. `??` remains
rejected. APIs should not manufacture optional results merely to avoid designing a useful
failure mode.

Optional placement is structural: an optional collection and a collection of optional
elements are different types. A literal containing `nothing` requires contextual element
type information. A function that returns a value on some paths and `nothing` on others
requires an explicit optional return type, and never acquires an implicit `nothing` by
falling off the end.

**Optionals never nest.** This is a general rule, not a special case for any one operation.
Writing `Int??` is an error that explains that an optional is already absent-or-present and
suggests the single `?`. It is unrelated to the `??` coalescing operator rejected above,
which is not a spelling in Emerald at all. Applying an optional-producing operation to an
already-optional type yields that same type rather than a second layer.

The rule is what makes the one optional relationship in 4.2 sufficient, and it has one
honest cost: an operation that reports absence through `nothing` cannot distinguish “no
answer” from “the answer was `nothing`” when the values themselves are optional. Emerald
accepts that loss and supplies an unambiguous companion for every affected operation
rather than introducing nesting:

| Lossy on optional elements | Unambiguous companion |
| --- | --- |
| `list.find { ... }` | `list.find_index { ... }` — an index is never `nothing` |
| `list.first`, `list.last` | `list.empty?()` |
| `dictionary[key]` | `dictionary.contains_key?(key)` |
| `list.min`, `list.max` | `list.empty?()` |

Documentation for these operations must state the limitation and name the companion. A
program that stores `nothing` as a meaningful element and also needs to detect absence uses
the companion; this is rare enough in beginner code that nesting would be the worse trade.

## 5. Expressions and operators

### 5.1 Literals

Settled literal forms include decimal integers, decimal floating-point numbers, `true`,
`false`, `nothing`, strings, and collection literals. Underscores may separate digits but
may not lead, trail, or repeat. A decimal point or exponent makes a literal a `Float`;
scientific notation accepts signed exponents. Additional numeric bases and suffixes are
deferred.

Tokens beginning with familiar unsupported base prefixes such as `0x`, `0o`, or `0b`
receive a targeted diagnostic rather than splitting into misleading decimal and identifier
tokens. Malformed separators, decimal points, and exponents likewise report one numeric
literal error spanning the attempted token.

Double-quoted strings process escapes and interpolation:

```emerald
var count = 3
print("There are #{count} gems.\n")
print("\#{count}") # literal #{count}
```

Single-quoted strings are raw: they do not interpolate and do not process backslash
escapes.

```emerald
var windows_path = 'C:\Users\student\game'
var pattern = '\d+'
```

Triple double quotes form multiline strings. The opening newline is omitted, indentation
matching the closing delimiter is removed from each content line, and there is no implicit
trailing newline. Interpolation and escapes retain their double-quoted meanings.

The text of a triple-quoted string begins on the line after the opening `"""`, and the
closing `"""` stands on a line of its own; each is an error otherwise, since neither the
indentation nor the omitted newlines would be well defined. A content line indented less
than the closing delimiter is an error, except a blank one. Indentation is removed before
escapes are processed, so an escaped `\n` is never taken for a line break, and a Windows
line ending in the source becomes `\n`.

The escapes are `\n`, `\t`, `\r`, `\0`, `\\`, `\"`, `\'`, and `\#`, plus `\u{...}`, which
writes a Unicode scalar value as one to six hex digits: `"cafe\u{301}"`. It exists for
characters that are invisible or impossible to type, such as a combining accent. An
interpolation may contain any expression, including another string with interpolations,
and displays its value as `print` would.

### 5.2 Boolean and comparison operators

Use the word operators `not`, `and`, and `or`. Symbolic duplicates such as `!`, `&&`, and
`||` are not a second spelling.

Comparison operators are `==`, `!=`, `<`, `<=`, `>`, and `>=`. Chained comparisons are
supported: `0 <= score <= 100` evaluates the middle expression once and short-circuits as
if the comparisons were joined by `and`.

`==` and `!=` compare two values of the same type, and an `Int` with a `Float` (4.4). The
ordering operators apply only to types with an order: numbers, and strings (9.2). `true <
false` is rejected rather than given a meaning a reader would have to guess.

Assignment is a statement, never an expression. Therefore `if x = 5` is rejected instead
of assigning accidentally.

Chained assignment is rejected, and declarations introduce one binding at a time except
for tuple destructuring. Compound assignment evaluates its receiver and index, checks and
reads the current value, then evaluates the right side; every subexpression runs at most
once. Function arguments and other ordered expression lists evaluate left to right.

A function call may discard its result when invoked for side effects. A standalone pure
expression with an unused result is an error; diagnostics should suggest the likely update,
such as replacing `score + 1` with `score += 1`.

### 5.3 Arithmetic

Arithmetic uses ordinary precedence. Exponentiation binds more tightly than unary minus
and is right-associative, so `2 ** 3 ** 2` means `2 ** (3 ** 2)` and `-2 ** 2` means
`-(2 ** 2)`.

The operators are:

- `+`, `-`, `*`
- `/` for ordinary division
- `//` for floor division
- `%` for the remainder paired with the chosen division rule
- `**` for exponentiation

Integer overflow is checked and reported against the 64-bit signed range settled in 4.2.
Every arithmetic operator, compound assignment, and `Int` conversion checks; overflow
raises rather than wrapping, and its diagnostic names the operation and both operands.
Negating the minimum `Int` overflows like any other operation. Division by zero is an error
for both numeric types. Floating-point overflow may produce infinity and invalid floating
operations may produce NaN; NaN follows IEEE comparison behavior and is inspected with
`nan?()`. NaN is invalid as a dictionary key, set element, or recursively contained part of
either. Sorting, `min`, and `max` report an error when they encounter NaN. Infinity orders
normally.

`/` always returns `Float`. `//` rounds toward negative infinity; two `Int` operands return
`Int`, while either `Float` operand makes the result a whole-number-valued `Float`. `%`
uses the matching floor-division law `a == (a // b) * b + (a % b)`; for finite operands a
nonzero remainder has the divisor's sign. Two `Int` operands return `Int`, otherwise it
returns `Float`. A NaN or infinite remainder operand produces NaN.

`**` follows `//`: two `Int` operands return an `Int`, checked for overflow like every other
`Int` operation, and either `Float` operand makes the result a `Float`. So `side ** 2` stays
a whole number when `side` is. An `Int` cannot hold the fraction a negative exponent
produces, so a negative `Int` exponent raises, and its diagnostic suggests a `Float` base such
as `2.0 ** -1`. `**` binds more tightly than unary minus and associates right to left.

Compound assignment includes `+=`, `-=`, `*=`, `/=`, and `//=` and lowers through the same
operation as the corresponding binary operator. `++` and `--` are omitted.

### 5.4 Calls, member access, and indexing

Ordinary calls use parentheses; the trailing-lambda form is the one exception:

```emerald
move(3, 4)
player.rename("Ava")
player.save()
numbers.map { number => number * 2 }
```

Square brackets perform zero-based indexing on indexable values. Out-of-range access is an
error with the requested index and valid range in the diagnostic.

Lists and strings slice with range syntax, producing independent values:

```emerald
text[1..<4]       # exclusive end
text[1..4]        # inclusive end
items[2..<]       # through the end
items[..<3]       # from the beginning
```

String boundaries count graphemes. Endpoints outside valid boundaries, and a start after
the end, are errors rather than silently clamped or emptied; an exclusive endpoint may equal
the length, and `items[i..<i]` is empty at any valid boundary. An inclusive endpoint names
an existing item. Omitted endpoints exist only inside slicing brackets and do not create
unbounded range values. A dictionary does not slice, and a parenthesized `Range` used as an
ordinary index remains a type error.

Method chaining is the pipeline notation:

```emerald
input("Age: ").trim().to_int_maybe().or(0)
```

No separate pipeline operator is needed.

A property uses no parentheses. Omitting parentheses from a method obtains a bound callable
value. Class receivers remain shared; struct receivers are copied into the bound method
and retain their private evolving copy across calls. An explicit closure captures a struct
binding when calls should update that surrounding binding.

## 6. Statements and control flow

### 6.1 Blocks and scope

Every control-flow or callable block creates a lexical scope. A local declared inside the
block does not leak out. A loop variable is a fresh binding for each iteration so closures
created in the loop capture that iteration's value.

Shadowing a visible local within the same function is an error because beginners usually
meant assignment. Sibling scopes may reuse names. Crossing a function boundary is allowed:
a parameter or local may reuse a module-level name.

### 6.2 Conditional statements and expressions

The statement form is:

```emerald
if temperature < 0 {
    print("Freezing")
}
else if temperature < 20 {
    print("Cool")
}
else {
    print("Warm")
}
```

The single-expression form is available for developer happiness:

```emerald
var label = if score >= 10 then "winner" else "playing"
```

Teaching material begins with statement blocks. The expression form requires both answers
and both answers must have a compatible type. Its condition must be `Bool`; the condition
runs once, and only the chosen answer runs. Both answers are statically checked, with the
condition's narrowing available in the corresponding answer. Result types follow the same
rules as value-producing `case`: `Int` and `Float` give `Float`, an answer of `nothing`
makes the other type optional, and sibling classes infer their nearest shared base.
An expected collection or function type flows into both answers.

Each answer is a full expression, so `if ready then 1 else 2 + 3` adds only in the
`else` answer; write `(if ready then 1 else 2) + 3` to add after choosing. Nested
choices need no extra syntax: `if first then a else if second then b else c`.
`return if ready then a else b` returns a chosen value, while `return if ready` remains
a guard on a bare return. Ordinary newline-continuation rules apply; parentheses allow
the expression to be spread across lines.

A trailing `if` makes one statement conditional, on one line. It is the guard form:

```emerald
return if not valid?()
print("Bonus") if score > 100
```

The trailing form has no `else` and applies to exactly one simple statement: a call, an
assignment, `return`, `break`, or `continue`. A declaration cannot take one, since the
name would be scoped to a block that ends on the same line. The three
forms have distinct jobs: the block `if` branches, the trailing `if` guards one action, and
`if ... then ... else` chooses a value.

There is no `unless`. It only ever meant `if not`, and a second spelling of the same
condition is the kind of choice principle 4 keeps out of the core syntax; negated compound
conditions such as `unless done or not ready` are also notoriously hard to read. `if not`
says the same thing in words a beginner already knows.

### 6.3 `case` and `when`

`case`/`when` is settled as a real construct, with a narrow and readable initial model:

```emerald
case direction {
    when Direction.north {
        move_up()
    }
    when Direction.south {
        move_down()
    }
    else {
        stay_still()
    }
}
```

Subject cases evaluate their subject once, test alternatives from top to bottom using
`==`, execute the first match, and never fall through. Commas allow several alternatives
in one arm. A statement case may omit `else`, in which case no match does nothing. Range,
destructuring, class, and user-defined matching remain deferred.

A value-producing case uses `then` and requires exhaustive coverage:

```emerald
var label = case score {
    when 1 then "First"
    when 2, 3 then "Placed"
    else then "Unplaced"
}
```

A subjectless `case` is also supported; each `when` is a `Bool` condition. Value-producing
enum cases may omit `else` when all values are covered. Nonexhaustive enum statement cases
produce a warning unless an explicit `else` acknowledges the remainder. Known duplicate
alternatives are errors. Each arm has its own lexical scope.

Every arm of one `case` has the same form: a block, or `then` and one value on the arm's
line. A block `case` in value position, or a `then` case whose value is unused, is an
error. A subjectless `when` takes exactly one condition, joined with `or` rather than
commas, and each arm is checked knowing its own condition held and every earlier one
failed, as an `if` chain is. Alternatives are evaluated in order only until one matches.
Coverage is known for an enum subject, for `Bool` (`true` and `false`), and for `nothing`
when the subject may be absent; a `when nothing` arm matches absence. A statement `case`
that covers every value runs one of its arms, so returns and definite assignment treat it
as complete. Value arms agree on a type, with `Int` and `Float` giving `Float` and a
`nothing` arm making the result optional. Known duplicates are literals and enum values;
numbers compare by value, so `when 1.0` repeats `when 1` when both are exact in `Float`.
A nonexhaustive statement `case` with a coverable subject (an enum or `Bool`) and no `else`
is a warning (17.1's `Diagnostic.Severity`), reported but not stopping checking; an `Int` or
`String` subject can't be exhausted, so no warning applies there, and an explicit empty
`else { }` acknowledges the gap deliberately.

### 6.4 Loops

The core loops are `while` and `for`:

```emerald
while lives > 0 {
    play_turn()
}

for name in names {
    print(name)
}
```

`break` exits the nearest loop and `continue` starts its next iteration. Guard forms may
be used where the resulting control flow stays obvious. Loop bindings are read-only and
fresh for every iteration. Range endpoints are evaluated once before iteration begins.
`for _ in 1..3` repeats without naming the value.

Definite assignment (4.1) treats a loop body as something that may run zero times, so a
name assigned only inside a loop is not known to be assigned after it, and the diagnostic
says the loop might not run. `while true` is the exception, because only `break` ends it:
after it, a name is assigned when every `break` assigned it, and a `while true` with no
`break` never completes, so a function may end in one that only `return` leaves. Only a
literal `true` counts, so the rule is one a reader can apply by eye.

`..` includes both bounds and `..<` excludes the upper bound. Ranges only count upward. A
range whose start is past its end is empty:

```emerald
for number in 1..5 {
    print(number)
}

for index in 0..<count {
    print(index)
}
```

Counting upward only is what makes computed bounds safe. `for i in 0..items.count - 1`
visits nothing for an empty list, and `for i in 1..n` visits nothing when `n` is `0`. A
range that reversed itself would visit `0, -1` and `1, 0` instead, failing only at the edge
case where a beginner is least likely to look. The rule is that the code states the
direction, never the values.

Counting down is therefore said in words, and a step says how far:

```emerald
for number in 10.down_to(1) {        # 10, 9, ..., 1
    print(number)
}

for number in 10.down_to(0).step(2) {  # 10, 8, 6, 4, 2, 0
    print(number)
}

for number in (0..10).step(3) {      # 0, 3, 6, 9
    print(number)
}

for number in (1..10).reverse() {    # 10, 9, ..., 1
    print(number)
}
```

`up_to` counts only upward and `down_to` only downward, and both include their target. A
target on the wrong side counts nothing, exactly as a range whose start is past its end
does, so `count.down_to(1)` is empty when `count` is `0` and `(0..<items.count).reverse()`
walks any list backwards safely, including an empty one. `up_to` is the method spelling of
`..`, kept as `down_to`'s companion. Both are loopable directly; the block form
`5.down_to(1) { number => print(number) }` is the same count with a lambda.

A range is also an immutable `Range` value: it can be stored, passed to a function, used
where a range is expected, and iterated later. Its `count` property is an `Int`, `empty?()`
answers whether it visits anything, and `to_list()` eagerly materializes its values as a
`List[Int]`. `step` and `reverse` return new Ranges. The count of the complete `Int` domain
does not fit in an `Int`; asking that Range for `count`, or trying to materialize it, raises
an ordinary runtime error with a correction toward narrowing it or using a larger step.

`step(distance)` takes a distance of at least 1; the range or method supplies the
direction, never the sign of the step. A count takes at most one `step`. `reverse()` visits
the same values in the opposite order. The two apply in the order written, so
`(0..10).step(3).reverse()` visits `9, 6, 3, 0`, while `(0..10).reverse().step(3)` visits
`10, 7, 4, 1`.

A count written with two literal numbers that can only be empty, such as `5..1` or
`1.down_to(5)`, is an error suggesting the spelling that counts the intended way: it can
only be a mistake, and an error cannot be scrolled past. A literal step below `1` is an
error too, and a computed one raises when the loop begins. Computed endpoints are never
reported, since an empty `0..count - 1` is the point of the rule.

Equal inclusive endpoints visit once, in every form. An equal half-open range is empty.

The Int block forms run the same Range semantics immediately and return `Nothing`:

```emerald
5.times { index => print(index) }
1.up_to(5) { number => print(number) }
```

`times` visits `0` through one less than its receiver and rejects a negative count. The
same `up_to` and `down_to` wrong-side rule applies to their block forms.

User-defined integration with `for` through an `Iterable` trait is deferred. Initial
`for` supports the built-in iterable types.

### 6.5 Returns and guards

`return` leaves the nearest function or lambda. It does not leave an enclosing function
when written inside a lambda.

A function returning no value has the return type `Nothing`, which may be written or
omitted, and it may use bare `return`. A recursive function that returns a value requires
an explicit return type so checking does not depend on circular inference (7.2).

A statement that follows one that can never complete — `return`, `raise`, `break`, or
`continue`, or an `if`/`case` every branch of which can't — is a warning (17.1), reported
once at the first such statement in its block. A nested function declared after a `return`
is not itself unreachable code: it is hoisted (7.1), so its position relative to a `return`
in the same block does not matter.

## 7. Functions and callable values

### 7.1 Declaration

The intended shape is:

```emerald
func add(left: Int, right: Int): Int {
    return left + right
}
```

`func` is settled. A colon introduces a return type. Function types reuse declaration
syntax—`func(Int): String`, `func(Int)`, and `func()`—while lambdas use `=>`. `->` is not
part of the callable surface.

Parameters are read-only bindings under the `const` rule of 4.3. A collection or struct
argument is the function's own copy, so a change to it would be lost when the function
returns; mutating it is therefore rejected rather than silently discarded. A class object
received through a parameter is shared, so mutating it is allowed and visible to the
caller. Assigning a different value to any parameter name is an error.

```emerald
func add_guest(guests: List[String], guest: String): List[String] {
    guests.append(guest)    # error: `guests` is a copy, so the change would be lost
    guests = []             # error: parameters are read-only

    var updated = guests    # an explicit working copy
    updated.append(guest)   # allowed
    return updated
}

party = add_guest(party, "Ava")
```

There is no `ref` or `inout`. Reference-type objects naturally expose shared state. A
struct or collection argument is passed according to value semantics, and a function that
changes one returns the changed value. The diagnostic for mutating a parameter says that
the change would be lost and suggests returning the changed value.

Function declarations are hoisted within their lexical scope; variables are visible only
from their declarations. Nested named functions are allowed, capture surrounding bindings
like lambdas, and are hoisted within their containing scope. Hoisting never permits reading
an uninitialized captured variable.

A nested function sees exactly what a lambda written in its place would: the variables
declared above it, shared by reference, which is also what a top-level function sees of
the module. It can be called anywhere in its block, including above its declaration and
by the other functions the block declares. A use of one is checked against every variable
it can reach, through the nested functions it calls: each must be declared above the use
and, if it is read, certainly assigned there. A nested function shares the one name space
of its enclosing function's locals, may not use `self` any more than a lambda can (7.4),
and takes defaults and named arguments like any named function (7.3).

### 7.2 Inference and annotations

Parameter annotations are normally explicit on named functions. Lambda parameter types
may be inferred from the expected callable type or the receiving collection method.
Return types may be inferred for nonrecursive functions when the body provides a clear
answer. Public API guidance may later recommend explicit return types without making them
syntax requirements.

Every reachable path in a value-producing function returns a value. Recursive functions
and mutually recursive cycles that return a value require explicit return types.

A function with no result returns `Nothing`. There is no separate "no result" category:
omitting the return type of a function with no value-returning `return` means `Nothing`,
and writing `: Nothing` means the same. Calling one produces `nothing`. Because that return
type is known without looking inside the body, such a function needs no annotation even
when it is recursive, so a recursive `countdown` is written like any other.

Every implementation supports at least 1,000 active Emerald calls and detects excessive
recursion before exhausting its host stack. Crossing an implementation's documented limit
raises a catchable `RecursionError`, preserves ordinary unwinding and `finally` behavior,
and reports the repeating source call with repeated frames summarized. The precise limit
above the portable minimum is a resource boundary rather than program semantics. There is
no initial API for changing it, and tail-call optimization is permitted but not
guaranteed.

### 7.3 Defaults and named arguments

Overloading is deferred. A name declares one function or method within its scope, and a
second declaration of the same name is an error naming the first. Selection is therefore by
name alone: there is no candidate set, no ranking, and no ambiguity report.

This reverses an earlier decision to support overloading, for three reasons. It was the
most expensive machinery in the design — static ranking over exact types, more-specific
class and trait types, `Int`-to-`Float` widening, defaults consumed, and name-based
elimination — layered over inference, narrowing, and trait subtyping. It produces the class
of diagnostic least compatible with principle 1, because “no overload matches” explains a
search the reader cannot see. And defaults with named arguments already cover most of what
overloading is reached for. Adding overloading later is backward compatible; removing it
would not be, so the reversible choice starts simple.

Two consequences are deliberate. Type-level factory functions replace overloaded
constructors, which reads better anyway: `Vector2.from_angle(radians)` says what
`Vector2(Float)` only implies. And mixed-type operators do not come from overloading:
11.5's `@operator` annotation registers each operand type on its own uniquely named method,
so ordinary method names stay unique.

Default-valued parameters follow required parameters:

```emerald
func greet(name: String, punctuation: String = "!") {
    print("Hello, #{name}#{punctuation}")
}
```

One required parameter may follow defaulted ones: a final parameter of function type, which
a trailing block supplies (7.4).

Named arguments may skip defaulted parameters and document call sites. A call must not
supply the same parameter twice or place positional arguments after named arguments. A
trailing block always fills the final parameter, whatever was named or left to a default
inside the parentheses, so `grid(2, height: 1) { x, y => ... }` is allowed. The
parameter name is part of public override and trait contracts. Explicit arguments evaluate
left to right as written, followed by omitted defaults in parameter order. A default may
read earlier parameters but not itself or later parameters. An override inherits the
original declaration's default and cannot replace it.

A subclass member whose name matches an overridable base member requires `@override` and
replaces it. A same-named member without `@override` is a diagnostic, as described in 10.7.
Because names are unique within a scope, there is no overload set to partially hide.

Variadic parameters are deferred. `print` and `write` accept zero or more values as a
prelude affordance described in 15.2, not as a general calling convention users can write.

### 7.4 Lambdas, trailing blocks, and capture

Lambdas are values and use the settled `=>` spelling:

```emerald
var double = { value => value * 2 }
var doubled = numbers.map { value => value * 2 }
```

A single-expression lambda returns its expression. A block-bodied lambda uses explicit
`return` when it produces a value. `return` exits the lambda itself.

A zero-argument lambda retains the arrow: `{ => do_work() }`. Standalone lambda parameters
must receive types either on the parameter or from an expected function type. `_` discards
an argument without introducing a binding and may appear more than once.

Lambdas accept the same finite parameter arities as named functions and have no separate
small maximum. Tuple destructuring may appear recursively in any lambda parameter
position; its shape and the overall callable arity are checked statically, and every bound
name remains read-only. This does not spread a dictionary entry into two parameters: an
entry is still one tuple item unless the method explicitly promises another argument.

Every method remains capturable. When a built-in higher-order method has an output type
that depends on a future block, a bare capture requires an expected callable type:

```emerald
const mapper: func(func(Int): String): List[String] = numbers.map
```

A capture such as `const mapper = numbers.map` lacks enough evidence to choose the mapped
element type and receives an inference diagnostic showing the needed annotation. Emerald
does not create an implicitly generic callable or defer the binding's type decision until
a later call. Methods whose signatures are already concrete infer normally.

Trailing lambdas provide Ruby-like block expressiveness without making blocks a second
calling convention. Parameter types are inferred when the receiver determines them.

Closures capture lexical variables by reference, allowing a block to update surrounding
state. Loop bindings remain fresh per iteration.

Creating a module-level lambda does not run its body. It may therefore capture a module
variable declared later, provided a call through its module binding comes only after that
variable has received a value. Calling it earlier remains a definite-assignment error.

`return` inside a lambda exits only that lambda invocation. `break` and `continue` cannot
reach out of a lambda to control an enclosing loop or an `each` call. A struct method may
not create a closure that later mutates its original `self`; explicitly copy `self` into a
local for private captured state. Class methods may capture shared `self` normally.

When a trailing lambda appears inside an `if`, `while`, or `for` header, parentheses group
the complete call before the statement body begins:

```emerald
if (items.any? { item => item.valid?() }) {
    print("Found one")
}
```

### 7.5 Method values

Methods are first-class callable values. `player.greet()` invokes the method and
`player.greet` captures it. Capturing any method is allowed. A class receiver remains the
shared object; a struct receiver is copied and the captured copy persists across calls.

The struct rule is ordinary value semantics rather than a special case, and it is taught
through its equivalence: capturing a method from a struct behaves exactly as if the struct
had been copied into a local first, with the method called on that local.

```emerald
const advance = counter.increment   # behaves like the two lines below
var private_copy = counter
const advance = private_copy.increment
```

Nothing the captured method does is visible through the original binding, because a struct
assignment never shares. A captured method that changes its copy keeps those changes from one
call to the next, so `const draw = office.next` counts up on every call while `office` stays
as it was. Like a changing method called directly (4.3), it has its copy to itself while it
runs, so calling the same captured method again from inside that call is a runtime error.

Capturing a method of `self` inside a constructor copies `self`, so it waits until every
field is set, exactly as calling one does (10.2), and a field default cannot capture one. Two
captured methods are equal only when they are the same captured value: each holds its own
copy, so two captures are different functions even when they come from equal values. Diagnostics for the related restriction in 7.4 — a struct method
may not create a closure that outlives and mutates its original `self` — should use this
same framing and suggest the explicit local, which makes the copy visible in the source.

## 8. Collections and compound values

### 8.1 Design

Collections behave familiarly: lists preserve order and duplicates, dictionaries map
unique keys to values, sets retain unique elements, and tuples hold two or more values.
Lists, dictionaries, and sets are mutable values: assignment and ordinary parameter
passing produce independent collection values. A `var` collection may be mutated in place.
A `const` collection cannot change at all (4.3), and a collection parameter is read-only in
the same way (7.1).

Copies are a semantic guarantee, not a physical one. An implementation shares storage
between copies until one of them is mutated, so passing a large list to a function costs
nothing unless the function copies it into a `var` and changes it.

The beginner vocabulary is intentionally small. A richer standard vocabulary remains
available through completion and documentation rather than being taught all at once.

### 8.2 Surface syntax

List syntax is settled:

```emerald
var scores = [10, 20, 30]
var names: List[String] = []
```

Built-in collection types use named bracketed forms: `List[T]`, `Dict[K, V]`, and
`Set[T]`. These are built-in type spellings, not user-defined generics.

Dictionary and set syntax is settled. Square brackets are the literal for all three
collections; a dictionary literal is recognized by its `key: value` entries, and a set
literal is a bracketed list of elements in a place whose type is a set:

```emerald
var ages: Dict[String, Int] = [
    "Ava": 12,
    "Noah": 13,
]

var seen: Set[String] = [
    "red",
    "green",
]
```

Nonempty list and dictionary literals normally infer their types. Without an expected set
type, a bracketed list of elements is a list, so a set needs its type written or a
conversion: `["red", "green"].to_set()`. A parameter or return type supplies the expected
type as well as an annotation does, so `colors.union(["blue"])` passes a set. Empty
literals require an explicit type because their elements cannot establish one:

```emerald
var names: List[String] = []
var ages: Dict[String, Int] = []
var seen: Set[String] = []
```

Only a literal takes its kind from the expected type. A list already stored in a binding
stays a list, so `var seen: Set[String] = names` is a type error whose correction is
`names.to_set()`.

Printing is unambiguous even though the literals overlap. A dictionary writes its entries,
`["Ava": 12]`, and an empty one writes `[:]`; a set writes the braces of its type,
`{"red"}`, and an empty one `{}`. So a printed collection always says which of the three it
is, which a bare `[]` could not.

Braces after control-flow and declaration headers begin blocks. Braces in expression
position begin a lambda, and nothing else, so a lambda is never confused with a
collection and a literal in a `for` header needs no grouping:

```emerald
for number in [1, 2, 3] {
    print(number)
}
```

Tuple syntax is settled and follows its arity:

```emerald
var entry: (String, Int) = ("score", 10)
var result: (String, Int, Bool) = ("Ada", 36, true)
var (name, age, active) = result
```

Tuples require at least two elements. `(value)` and `(value,)` are grouped expressions;
a trailing comma never changes an expression's type. `()` is not a tuple or unit value.
Functions with no result already use `Nothing`.

Tuple positions use zero-based member access such as `entry.0` and `entry.1`; an invalid
position is a compile-time error. A tuple has no `count`: its size is part of its type and
is written where the tuple is, so there is nothing to ask at runtime.

`entry.0.1` reaches a position of a position. The lexer reads `0.1` as one decimal number,
because a `.` between two digits is a decimal point, and the parser splits it back into two
positions where it knows a member is being named. This is the same kind of lexical rule as
4.2's `Int?`, and it is recorded here for the same reason: an implementation that skips it
rejects a program that should work.

A tuple cannot be assigned to a position, so a `(Int, Int)` may be used where a
`(Float, Int)` is expected, widening position by position. This is unlike a list, which is
invariant precisely because it can be written through (4.4).

Destructuring must match the arity and works in declarations, `for` bindings, the
parameters of a block (8.6), and assignment. A position may itself be unpacked, as in
`const (label, (x, y)) = entry`, in every one of those places. `_` discards a position wherever
a tuple is unpacked. Existing
local bindings may be updated together:

```emerald
(left, right) = (right, left)
```

The complete right side is evaluated before any destination changes. Initial assignment
targets are mutable local names or `_`; field and index destinations are deferred.

### 8.3 Indexing and dictionary misses

List and string indexing is zero-based. Negative indexing is not assumed for v1; add it
only after deciding how it interacts with ranges and out-of-bounds diagnostics.

Dictionary bracket lookup can miss and therefore produces an optional value:

```emerald
var score = scores["Ava"].or(0)
```

Bracket assignment inserts a new entry or replaces the existing value. A dictionary whose
value type is already optional does not produce a nested optional on lookup: both a missing
entry and a stored `nothing` read as `nothing`, while `contains_key?` distinguishes them.
This is the general non-nesting rule of 4.5 rather than a dictionary-specific exception.
Assigning `nothing` stores an entry when the value type permits it and never means deletion.

Dictionary keys must have stable equality and hashing. Built-in scalar values, strings,
enums, and structs or tuples whose contents recursively qualify are initial candidates. An
optional is not a key: an absent key is not a key at all. A set's members answer to the
same rule, because a set stores and finds them the way a dictionary stores and finds keys.
Stored value-type keys are copied, so later mutation of the original cannot invalidate
lookup. Classes and collections are not dictionary keys, for the same reason lists are not:
their contents can change after they are stored, which is exactly what could not then be
found again. NaN is rejected directly or recursively.

A struct that adopts `Hashable` (8.4) is a key through its own `equals()`/`hash()` instead
of the structural default; one that adopts `Equatable` without also adopting `Hashable` is
excluded, even though it would otherwise qualify, because its default structural hash could
then disagree with its custom `equals` — the checker names this reason specifically, rather
than folding it into the generic "cannot be a key" message. `Hashable` does not lift the
class exclusion above: a class's fields can still change while it is stored, whatever its
`equals`/`hash` compare.

### 8.4 Equality and order

A struct or class may adopt `Equatable` (11.5) to replace the default `==`/`!=` — structural
for a struct or tuple, identity for a class — with its own `equals(other: Self): Bool`;
`!=` is always `not equals(other)`, never separately overridable. Adoption is explicit, as
for any trait (11.2): declaring `equals` without `with Equatable` is a warning, not a
behavior change, the same as `to_string` without `Textual` (15.1). `Hashable`, which
requires `Equatable` (11.2's trait composition), adds `hash(): Int` and is what actually
makes a struct a dictionary or set key through that pair of methods rather than the
structural default (8.3) — adopting `Equatable` alone changes comparison but not key
eligibility.

Lists compare element-by-element in order. Sets compare by membership. Dictionaries
compare by key/value contents rather than insertion order. Tuples compare their values
position by position.
All recursive comparisons use Emerald's `==`.

Dictionaries and sets preserve insertion order for iteration and stable printing, even
though order is not part of their equality. Replacing a dictionary value keeps its
position; removing and reinserting a key moves it to the end. A `for` loop iterates the
collection snapshot captured when the loop begins, so later mutation never changes the
visited sequence.

Repeated elements in a set literal collapse to one. A statically known duplicate dictionary
literal key is an error; when calculated keys collide at runtime, the later value wins
without changing its insertion position.

Hash values and the hashing algorithm are runtime details, not stable Emerald output.
Equal eligible keys must hash compatibly within a process, but implementations may seed or
replace their algorithms between runs and releases. Observable dictionary and set order
comes from the specified insertion order rather than hash-table layout. Serialization,
tests, and user-facing identity must never depend on a hash value.

### 8.5 Essential methods

The first teaching vocabulary is:

| Family | Essential methods |
| --- | --- |
| All collections | `count`, `empty?`, `each` |
| List | `contains?`, `append`, `insert`, `remove`, `remove_at`, `remove_first`, `remove_last`, `clear`, indexed access |
| Dictionary | bracket lookup and assignment, `contains_key?`, `contains_value?`, `keys`, `values`, `entries`, `remove`, `merge` |
| Set | `add`, `remove` |

Collection size is the read-only `count` property rather than a zero-argument method.
`first` and `last` are also read-only properties on ordered collections.

`List.remove(element)` removes the first equal value and quietly does nothing when the
value is absent. `remove_all(element)` removes every equal value. Both return `Nothing`.
`remove_if` may remove all values matching a block. Index removal remains the distinct
`remove_at(index)` operation.

`remove_at(index)`, `remove_first()`, and `remove_last()` return the element they remove,
and removing from an empty list is an error rather than an optional result, matching the
strict bounds of indexing. `insert(index, element)` accepts any index from `0` through
`count`; inserting at `count` appends. `append`, `insert`, `remove`, `remove_all`,
`remove_at`, `remove_first`, `remove_last`, and `clear` change the list they are called on,
so they are rejected on a `const`, a parameter, or a loop variable (4.3, 7.1), and on a
temporary such as `make_list().append(1)`, where the change could never be seen.

A list displays the way it is written, with its elements displayed in turn: `[1, 2, 3]`,
`[[1.0], []]`.

### 8.6 Rich vocabulary

The accepted discoverable vocabulary includes the following families, subject to their
natural applicability and exact return-type review:

- traversal: `each`, `each_with_index`, `reverse_each`;
- questions: `empty?`, `contains?`, `any?`, `all?`, `none?`, `one?`, `count_where`;
- searching: `find`, `find_index`, `first`, `last`;
- transformation: `map`, `filter`, `reject`, `flat_map`, `filter_map`;
- portions: `take`, `drop`, `take_while`, `drop_while`;
- grouping: `group_by`, `partition`, `frequencies`;
- aggregation: `reduce`, `sum`, `average`, `min`, `max`, `min_by`, `max_by`, `min_max`;
- combining and shapes: `zip`, `chain`, `chunks`, `windows`, `pairs`;
- ordering: `sort`, `sort_by`, `reverse`, `shuffle`;
- uniqueness: `unique`, `unique_by`;
- conversion: `to_list`, `to_set`, `to_dictionary`.

Dictionary-specific transformation includes `map_keys`, `map_values`, and tuple-aware
`filter`. Sequence-to-dictionary construction includes `associate` and `associate_by`.
Set operations use the explicit names `union`, `intersection`, `difference`,
`symmetric_difference`, `subset?`, `superset?`, and `disjoint?`; comparison operators do
not stand for subset relationships.

Every ordinary collection block receives one logical item. A dictionary's item is a
two-element `(key, value)` tuple, which may be destructured directly:

```emerald
ages.each { (name, age) =>
    print("#{name} is #{age}")
}
```

There is no second implicit `key, value` calling convention. A method such as
`each_with_index` explicitly promises its additional parameter:

```emerald
ages.each_with_index { (name, age), index =>
    print("#{index}: #{name}")
}
```

The entry-tuple rule also applies to `map`, `filter`, `find`, and other general dictionary
operations. Dedicated methods such as `map_keys` and `map_values` receive only the part
named by the method.

Ordinary collection pipelines are eager. Transformations preserve input order unless
they explicitly sort or reverse, evaluate blocks from left to right exactly once per
visited value, and produce new collections. `find`, `any?`, `all?`, `none?`, and `one?`
stop as soon as their answers are known. Dictionary and set iteration is deterministic.
Invalid indices and sizes produce clear errors rather than being silently adjusted.
Looping over a range need not allocate a list, but an eager transformation such as
`range.map` returns a completed list before the next operation begins.

`each` is for side effects and returns `Nothing`. `reduce` requires an initial value, so
empty input is defined and the accumulator may differ from the element type. `filter_map`
takes a block returning an optional, discards `nothing`, and returns a list of the present
values.

Methods that can miss, such as `find`, `first`, `last`, `min`, and `max`, return an
optional. Membership must not be implemented by comparing `find` with `nothing`, because a
collection may itself contain `nothing`; use `contains?`, or `find_index` when the matching
position is needed. This follows the non-nesting rule and companion table in 4.5.

`filter` and `reject` preserve the receiver's collection kind for lists, dictionaries,
and sets. `take(count)` and `drop(count)` do the same, using insertion order for
dictionaries and sets. The corresponding operations on a range return a completed list.
Strings and heterogeneous tuples do not receive these general collection operations
initially.

A negative `take` or `drop` count is an error. Zero is valid. A count beyond the available
items is not an error: `take` returns every item and `drop` returns an empty collection.
This deliberately differs from the strict bounds of `substring(start, count)` because
`take` and `drop` describe portions rather than exact indexed spans.

The first value-transform slice applies `take`, `drop`, `reverse`, and `unique` to lists.
Each returns a new list and leaves its receiver unchanged. `reverse!` and `unique!` are the
in-place counterparts; `unique` keeps the first occurrence of each equal item and
preserves the order of those first occurrences. The non-bang forms remain usable on a
`const`, while the bang forms need a changeable list as every other list mutation does.

`filter` and `reject` are available on Lists, Dictionaries, and Sets. Each calls its
predicate once, left to right, returns a new collection of the receiver's kind in input
order, and leaves the receiver unchanged. `filter` keeps the items whose predicate is true;
`reject` keeps those whose predicate is false. A Dictionary predicate receives its usual
destructurable `(key, value)` entry, while a Set predicate receives its member.

`each_with_index` is available on Lists, Dictionaries, and Sets. It returns `Nothing` and
calls its block once for each logical item, left to right, with that item followed by its
zero-based `Int` position. A Dictionary's first argument remains its destructurable
`(key, value)` entry. Its positions therefore follow List order and the deterministic
insertion order of Dictionaries and Sets.

`reverse_each` is available on Lists, Dictionaries, and Sets. It returns `Nothing`, visits
the existing items from last to first (a Dictionary or Set following its deterministic
insertion order), and does not change its receiver.

The predicate questions `any?`, `all?`, `none?`, and `one?`, plus `count_where`, are
available on Lists, Dictionaries, and Sets. Each takes a `Bool`-producing block over one
logical item; a Dictionary item remains its `(key, value)` entry. `any?`, `all?`, and
`none?` stop at the first accepted or rejected item that decides their answer, and `one?`
stops at its second accepted item. `count_where` visits every item. On an empty collection,
the answers are `false`, `true`, `true`, `false`, and `0`, respectively.

`take_while` and `drop_while` are currently List operations. Both evaluate a `Bool`
predicate from the beginning of the List. `take_while` returns the matching prefix and stops
before the first failing item; `drop_while` omits that prefix, includes the first failing item
and every later item, and does not call its predicate again. They return new Lists and leave
their receiver unchanged. An empty List returns an empty List without calling the block.

`flat_map` is available on Lists, Dictionaries, and Sets. Its block must return a List for
each input item; the result contains those produced items in input and produced-List order,
always as a new `List` regardless of receiver kind. It flattens one level only, so a
produced List containing Lists retains those inner Lists as values. Empty produced Lists
contribute no items. `flat_map` returns a new List and leaves both its receiver and every
List returned by the block unchanged. An optional List result is not accepted as an empty
List; `filter_map` has its own explicit presence rule.

`filter_map` is available on Lists, Dictionaries, and Sets. Its block returns `T?` for each
input item; present results become items in a new `List[T]`, while `nothing` contributes no
item. It visits every input item once, in the receiver's order, and leaves the receiver
unchanged. This does not flatten a present List result: a block returning `List[Int]?`
produces `List[List[Int]]`. A block returning a non-optional value is rejected with a
correction toward `map`, rather than silently treating every result as present.

`reduce(initial) { accumulator, item => ... }` is currently a List operation. It evaluates
the initial value once, then visits items from left to right; each block result becomes the
next accumulator and the final accumulator is returned. The initial value also determines the
result and accumulator type, which may differ from the List's element type. The block must
take that accumulator followed by one List item and return the accumulator type. Because the
initial value is required, an empty List simply returns it. `reduce_right(initial) { accumulator,
item => ... }` is the same shape, visiting from the List's end toward its start; Dictionary and
Set forms of both remain deferred. As with every List traversal, changing a captured binding
during the block changes that binding's copy and does not add or remove items from this
reduction.

`sum()` is currently a List operation for `List[Int]` and `List[Float]`. It returns that same numeric
type and visits items from left to right. An empty numeric List returns its additive identity:
`0` for `List[Int]`, or `0.0` for `List[Float]`. Int accumulation checks overflow at every addition;
Float accumulation follows Emerald's ordinary IEEE-754 arithmetic, including `Infinity` and
`NaN`. Other List element types receive a correction toward mapping to numbers first.

`average()` is currently a List operation for `List[Int]` and `List[Float]`. It returns `Float?`:
`nothing` for an empty List, otherwise the arithmetic mean after each Int has widened as it
would for an ordinary Float operation. This keeps a fractional Int-list result visible, such
as `[1, 2].average()` yielding `1.5`. Float accumulation and division follow ordinary
IEEE-754 arithmetic, including `Infinity` and `NaN`.

`min()` and `max()` are currently List operations for `Int`, `Float`, `String`, and user
types that adopt `Ordered`. They return `T?`: `nothing` for an empty List, otherwise the first
item tied for the requested extreme. A List of optional values is rejected so that `nothing`
unambiguously means the List had no items; `filter_map` removes absent values first. `NaN` has
no order, so either operation reports an error when it encounters one. `empty?()` is the
companion when a program needs to distinguish an empty List from a List whose element type can
otherwise represent absence.

`min_by { item => key }` and `max_by { item => key }` are currently List operations. They
return the first tied List item as `T?`, or `nothing` for an empty List; the block supplies one
ordered, present key per item. Keys may be `Int`, `Float`, `String`, or a type adopting
`Ordered`. A `NaN` key reports an error, as it has no order. Optional List elements and
optional keys are rejected to keep absence unambiguous; use `filter_map` or `.or(...)` first.

`min_max()` is currently a List operation for the same ordered element types as `min()` and
`max()`. It returns `(T?, T?)` after one left-to-right traversal: the first position is the
first tied minimum, the second the first tied maximum, and an empty List returns
`(nothing, nothing)`. Optional elements and `NaN` follow the same rejection rules as the
individual extrema.

`sort()` and `sort!()` order a List using the same Int, Float, String, and `Ordered`
contracts as `min()` and `max()`. `sort()` returns a new List and leaves its receiver
unchanged; `sort!()` changes the receiver and returns `Nothing`. Sorting is stable, so equal
items keep their input order. Optional elements are rejected, and encountering `NaN` raises
because it has no order. `sort_by { item => key }` computes one present ordered key per item,
left to right, and returns a new stable ordering of the original items; a `NaN` key raises.

`unique_by { item => key }` computes one dictionary-eligible key per List item and keeps the
first item for each key in input order. `associate { item => (key, value) }` builds a
Dictionary from produced entries, while `associate_by { item => key }` uses each original
item as its value. `to_dictionary()` converts a List that already contains two-element
tuples. All three dictionary builders preserve the first insertion position for a repeated
key and replace its value with the last produced value, matching ordinary Dictionary
assignment.

The `!` convention has a narrow meaning: it marks an in-place counterpart to a plain
method that returns a new value. Thus `sort()`/`sort!()`, `reverse()`/`reverse!()`,
`unique()`/`unique!()`, and `shuffle()`/`shuffle!()` form pairs. Inherently mutating verbs
such as `append`, `insert`, `remove`, `clear`, and filesystem `delete` remain plain because
there is no value-producing method of the same name.

Queries that may have no answer—`first`, `last`, `find`, `find_index`, `min`, `max`, and
`average`—return an optional. `count` remains `0` and `sum()` returns the additive identity
for a statically known element type on empty input.

User-defined `Iterable` conformance and `for` integration are deferred. Built-in
collections may share internal implementation without exposing a general generic protocol
prematurely.

## 9. Strings and numbers

### 9.1 Unicode strings

`String` is immutable and Unicode-aware. User-facing character operations use extended
grapheme clusters, so a displayed character such as an accented letter or family emoji is
not split accidentally.

The user-friendliness tradeoff is settled in favor of direct zero-based indexing despite
the fact that locating a grapheme may be linear time:

```emerald
var greeting = "héllo 👋"
print(greeting[0])
```

Documentation must state the cost honestly. The implementation may build internal indexes
or caches later without changing semantics.

Iteration yields grapheme strings. Separate advanced conversions expose Unicode code
points and encoded bytes when required; beginner APIs should not call those “characters.”

Substring work is method-based so its cost is not disguised as constant-time indexing:

```emerald
word.substring(start)
word.substring(start, count)
```

Indices and counts are measured in graphemes. `substring(start)` continues through the end
of the string. A start equal to the string's grapheme count is valid and produces `""`;
zero is a valid count. Negative arguments, a start beyond the end, or a requested count
that extends past the end raise a clear bounds error rather than being silently clamped.

### 9.2 Initial string vocabulary

The accepted vocabulary should be normalized to full descriptive names:

- size and conversion: `count`, `empty?`, `chars`, `code_points`, `bytes`, `to_string`;
- casing: `upper`, `lower`, `capitalize`;
- whitespace: `trim`, `trim_start`, `trim_end`, `blank?`;
- search: `contains?`, `starts_with?`, `ends_with?`, `index_of`;
- editing by result: `replace`, `insert_at`, `substring`, `reverse`, `repeat`,
  `remove_prefix`, `remove_suffix`, `collapse_repeats`;
- layout: `pad_start`, `pad_end`, `pad_center`;
- decomposition: `split`, `lines`;
- structural helpers: `partition`;
- parsing families: `to_int`, `to_int_or`, `to_int_maybe`, and corresponding float
  forms.

String methods do not mutate the receiver. `capitalize()` applies Unicode's
locale-independent uppercase mapping to the first grapheme and preserves the remainder
exactly. It returns an empty string unchanged. A future operation that also lowercases the
tail must use a name that promises that broader transformation.

`count` is a property and measures graphemes. `index_of` returns an optional index.
`lines()` omits newline characters by default: a line ends at `\n`, a `\r` before it
belongs to the ending, and a final line ending does not begin an empty last line.

`insert_at(index, text)` inserts before the grapheme at `index`; index `0` is the
start and `count` is a valid index that appends. A negative index or one beyond `count`
is an error. `remove_prefix(prefix)` and `remove_suffix(suffix)` each return the original
string unchanged when it does not match. Their match is canonical, as it is for equality,
and a successful removal preserves the receiver's remaining original bytes.

`collapse_repeats()` replaces each run of adjacent canonically equal graphemes with its
first grapheme. `partition(separator)` returns a three-part tuple of the text before the
first match, the matching text, and the text after it. Its separator cannot be empty; when
there is no match, it returns `(text, "", "")`.

`pad_start(width, fill = " ")`, `pad_end(width, fill = " ")`, and
`pad_center(width, fill = " ")` measure width in graphemes. `fill` must be exactly one
grapheme and a negative width is an error. A string at least as wide as the requested width
is unchanged. When center padding needs an odd number of fill characters, the extra one is
placed at the end: `"hi".pad_center(5, "-")` is `"-hi--"`.

Searching works in whole characters, as indexing does. `contains?`, `starts_with?`,
`ends_with?`, `split`, and `replace` match only where both ends of the match fall between
characters, and they compare canonically, as `==` does. So `"café".contains?("e")` is
false when the `é` is a single character: the `e` inside it is not a character of its
own, and 9.1 promises characters are never split. `trim` likewise removes whole characters
of Unicode whitespace. `replace(old, new)` replaces every occurrence; `split` with an empty
separator is an error that points to `chars()`, and `replace` with an empty `old` is an
error too.

`+` joins two strings, and `+=` appends. It is the one operator strings have, and it does not
convert: `"Score: " + 10` is an error suggesting `to_string()` or interpolation, which
remains the primary way to build prose.

Parsing is strict (9.4). `to_int` accepts an optional sign and decimal digits; `to_float`
accepts digits with an optional fraction and exponent, and also `Infinity`, `-Infinity`,
and `NaN`, so every displayed `Float` parses back. `to_string()` gives the display of an
`Int`, `Float`, or `Bool`.
`pad_start` and `pad_end` describe logical placement more clearly than left and right in a
Unicode language. `code_points()` returns the Unicode scalar values of the String's exact
stored spelling as `List[Int]`; a decomposed character therefore has more than one entry.
`bytes()` returns its exact UTF-8 bytes as `List[Int]`, each from 0 through 255. These are
advanced conversions, while `chars()` remains the grapheme-aware beginner API. `words`,
`title_case`, case-insensitive Unicode comparison, `letter?`, and `digit?` remain deferred
until their locale and boundary behavior can be designed correctly.

String equality uses canonical Unicode normalization, remains case-sensitive, and feeds
the same normalized equality into dictionary keys and sets. Ordinary string ordering is
deterministic and locale-independent, comparing normalized code points. Locale-aware
collation belongs in a later library facility.

**Normalization happens at comparison, not at construction.** A `String` retains exactly the
bytes it was built from, so reading a file and writing it back reproduces the original
bytes; `File.read` is not a lossy operation. Canonical equivalence is applied when two
strings are compared, hashed as dictionary keys, or tested for set membership.

The alternative, normalizing on construction, was rejected because it would silently rewrite
user data passing through the standard library — unacceptable in a language whose file
helpers are part of the beginner vocabulary.

The cost is that `==` is not a byte comparison. The implementation takes the obvious fast
paths: byte-equal strings are equal without further work, and a quick check that both
operands are already in NFC — true of nearly all real text — avoids allocating a normalized
form. Equal strings must hash equally, so the hash is computed over the normalized form
using the same quick check. These are performance details; the observable rule is only that
canonically equivalent strings are equal.

### 9.3 Numeric vocabulary

Useful value methods include:

```text
abs, clamp, between?, zero?, positive?, negative?, to_string
```

`Int` additionally supports:

```text
even?, odd?, multiple_of?, digits, gcd, lcm, factorial, times, up_to, down_to, to_float
```

`Float` additionally supports:

```text
floor, ceil, round, round_to, truncate, finite?, infinite?, nan?, to_int
```

The interval in `clamp(minimum, maximum)` and `between?(minimum, maximum)` is
inclusive. The minimum must be no greater than the maximum; reversing the bounds is an
error rather than a silent swap. This makes a misspelled interval visible to a beginner.

Integer signs do not change number-theory answers: `(-12).digits()` is `[1, 2]`,
`(-54).gcd(24)` is `6`, and `(-6).lcm(8)` is `24`. Digits are returned in the same
left-to-right order in which the number is written, and `0.digits()` is `[0]`.
`gcd(0, 0)` is `0`; an `lcm` with zero is zero. `multiple_of?` accepts negative divisors,
but a zero divisor is an error. Factorial accepts zero and positive integers, with
`0.factorial()` equal to `1`. An absolute value, GCD, LCM, or factorial that cannot fit in
the signed 64-bit `Int` range raises a runtime error rather than wrapping.

`times`, `up_to`, and `down_to` are the counting forms described in 6.4. `up_to` and
`down_to` produce ordinary `Range` values without a block and run that Range immediately
with a trailing block; `times` is the corresponding immediate block form.

`round_to(places)` rounds to a requested number of decimal places and returns a `Float`.
Positive places address digits after the decimal point, zero produces a whole-number-valued
`Float`, and negative places round to tens, hundreds, and so on. Halfway values round away
from zero, consistently with `round`. It changes the number and does not preserve display
zeros; `2.0.round_to(2)` is a numeric `2.0`, not the text `"2.00"`.

`floor()`, `ceil()`, `round()`, and `truncate()` return an `Int`; `round()` resolves a tie
away from zero, and `truncate()` discards the fraction toward zero. `to_int()` has the same
numeric result as `truncate()` but names an explicit type conversion, while `truncate()`
names the mathematical operation. All five reject NaN, infinity, and a result outside the
`Int` range. `round_to` accepts every `Int` place count: precision beyond binary64's decimal
range leaves a finite value unchanged on the fractional side and produces signed zero past
the whole-number side. It propagates NaN and infinity like floating-point arithmetic.

Both signed zeros answer true to `zero?()` and false to the sign predicates. NaN answers
false to `zero?`, `positive?`, `negative?`, `finite?`, and `infinite?`, and true only to
`nan?`. Infinity is not finite and answers `infinite?`. Infinite interval bounds are valid.
A NaN bound in `clamp` or `between?` is an error; a NaN receiver propagates through `clamp`
and makes `between?` false.

Operations naturally performed by one value are methods, including `square_root()` and
angle conversion such as `to_radians()`. `Math` holds broader operations and constants:
`pi`, `e`, `sin`, `cos`, `tan`, `arc_sin`, `arc_cos`, `arc_tan`, `arc_tan2`,
`natural_log`, `log10`, `log(value, base)`, and `power(base, exponent)`. Every function
accepts `Int` through ordinary numeric widening and returns `Float`; angles use radians by
default. The language operator `**` remains the natural ordinary power expression.

`Math` follows ordinary IEEE Float results: an inverse-trigonometric input outside its real
domain, a negative logarithm, an invalid logarithm base, or a negative base raised to a
non-integral power gives `NaN`; `natural_log(0)` gives `-Infinity`. These values are visible
and testable through the existing Float predicates rather than being special exceptions.
`Math` is a built-in namespace only when a project has not declared its own `Math` namespace,
so existing projects retain ownership of that ordinary namespace name.

Randomness is a standard-library service, not syntax. The beginner form chooses from a
range, making its bounds visible in the range itself:

```emerald
var die = random(1..6)
var index = random(0..<10)
var winner = players.random()       # optional when the collection is empty
var shuffled = cards.shuffle()
cards.shuffle!()
```

Repeatable work uses `Random(seed: 42)` with `next(range)`, `choose(collection)`, and
`shuffle!(collection)`. The global form delegates to a runtime-managed generator. Range
bounds retain the ordinary inclusive or exclusive meaning of their syntax, and choosing
from an empty range is an error.

`List.random()` returns an optional element and gives `nothing` for an empty List.
`shuffle()` returns a newly shuffled List without changing its receiver, while `shuffle!()`
changes a `var` List and returns `Nothing`. Both preserve every element and its multiplicity.
A seeded generator's `choose` has the same empty-List result, and its `shuffle!` requires a
changeable List place. Two generators created with the same seed and given the same sequence
of operations produce the same results; the precise sequence is an implementation detail and
must not be persisted as a portable format.

### 9.4 Standard-library recovery audit

The recovered conversation settles the library philosophy and the following public
vocabulary. It also resolves several names that were previously reconstructed from the
historical implementation.

| Family | Recovered rewrite decisions |
| --- | --- |
| `String` | The complete vocabulary in 9.2, including logical `pad_start`/`pad_end`, optional `index_of`, and the three-policy parsing families |
| `Int` | `abs`, `clamp`, `between?`, `zero?`, `positive?`, `negative?`, `even?`, `odd?`, `multiple_of?`, `digits`, `gcd`, `lcm`, `factorial`, `times`, `up_to`, `down_to`, `to_float`, `to_string` |
| `Float` | `abs`, `clamp`, `between?`, `zero?`, `positive?`, `negative?`, `floor`, `ceil`, `round`, `round_to`, `truncate`, `finite?`, `infinite?`, `nan?`, `to_int`, `to_string` |
| `List` | `append`, `insert`, `remove`, `remove_all`, `remove_at`, `remove_first`, `remove_last`, `clear`, plus applicable rich collection operations |
| `Dictionary` | bracket lookup and assignment, `contains_key?`, `contains_value?`, `keys`, `values`, `entries`, `remove`, `merge`, `map_keys`, `map_values`, plus applicable rich collection operations |
| `Set` | `add`, `remove`, `union`, `intersection`, `difference`, `symmetric_difference`, `subset?`, `superset?`, `disjoint?`, plus applicable rich collection operations |
| Tuple | two or more heterogeneous positions, positional structural equality, and destructuring |
| `Range` | ordinary iteration, `step`, eager rich transformations, and `times`, `up_to`, and `down_to` on integers |
| `Math` | `pi`, `e`, trigonometry, logarithms, and explicit power helpers; receiver methods cover natural single-number operations such as `square_root` |

The three parsing forms intentionally express three different failure policies:

```emerald
"42".to_int()          # return Int or raise a conversion error
"42".to_int_or(0)      # return Int or the supplied fallback
"42".to_int_maybe()    # return Int or nothing
```

The same family applies to floating-point parsing, so `to_int_maybe` returns `Int?` and
`to_float_maybe` returns `Float?`.
Parsing accepts surrounding whitespace but otherwise requires the entire string. Malformed
or out-of-range input raises for the strict form, returns the fallback for `_or`, and
returns `nothing` for `_maybe`.

`Float.to_int()` truncates toward zero. NaN, infinity, and values outside the `Int` range
raise a conversion error. This is deliberately distinct from `floor()` and `round()`.

Default `Float` display uses the shortest locale-independent decimal representation that
parses back to the same value. A finite whole value retains the marker needed to identify
it as a `Float`, such as `2.0`, and signed zero displays as `-0.0`. Scientific notation
uses lowercase `e` with an explicit exponent sign for nonzero magnitudes below `1e-6` or
at least `1e16`; the boundary values themselves therefore display in fixed and scientific
form respectively. Special values display as `Infinity`, `-Infinity`, and `NaN`. Explicit
numeric formatting remains the tool for fixed decimal places or other presentation needs.

The historical spellings that conflict with recovered rewrite decisions remain rejected:
`read_line` became `input`, `slice` became `substring`, `pad_left`/`pad_right` became
`pad_start`/`pad_end`, `has_key?` became `contains_key?`, `intersect` became
`intersection`, copy-sorting is `sort()`, and the old `Kernel` namespace is gone.

Before implementing a family, write a compact conformance table for parameter types,
return types, mutation, failure, empty-input behavior, Unicode or numeric boundary rules,
and one representative example. This is still required for a few collection lambda shapes
and nondecimal parsing bases. The recovered conversation already settles range direction,
eager evaluation, empty-query optionals, seeded reduction, parsing whitespace,
float-to-integer conversion, substring boundaries, rounding ties, and random bounds.

## 10. Structs, classes, and members

### 10.1 Value and reference semantics

Structs are value types. Assigning or passing a struct produces independent value
semantics. Classes are reference types. Assigning or passing a class value shares the same
object.

Structs may contain mutable `var` fields. This deliberately replaces the historical
prototype's immutable-struct rule. The language must implement real copying rather than
relying on immutability to make copying unobservable.

Classes compare by identity. Class values may be compared when their static types have an
inheritance relationship, so a subclass and base-typed reference can be recognized as the
same object; unrelated concrete class types are a compile-time mismatch. Structs compare
field-by-field by default:

```emerald
Vector2(1, 1) == Vector2(1, 1)   # true
```

A class stored inside a struct still compares according to class identity. Either default
can be replaced by adopting `Equatable`/`Hashable` (8.4, 11.5), designed together with
dictionary keys and set membership as this paragraph once anticipated.

A class declares the same members a struct does — stored fields with defaults, a
constructor, methods, properties, type-level members, and private members — and follows the
same construction rules. What differs follows from sharing. A change that reaches an object
changes that object where it is, whoever else holds it, so 4.3's `const` stops there: a
`const` binding, a parameter, a loop variable, a `const` list, or a temporary may all lead
to an object that changes, while a `const` field of the object, or a value held in one,
still cannot. A class method may change `self` and may be called through any of those, so
the checker never asks which class methods change `self`, and a block or nested function
inside one may use `self` (7.4). 4.3's rule that a changing call has its value to itself
does not apply to an object as a whole, which is shared by design, but it does apply to a
struct held in an object's field: a setter or changing method called on that struct takes
the field's value while it runs and puts the result back when it finishes, and reaching
that field another way meanwhile is a runtime error, exactly as for a variable. A getter of a class may change its object; 10.3's rule exists so a
property of a `const` struct can be read. A struct method that changes only an object the
struct holds does not change the struct.

An object displays like a struct, field by field. Objects can refer to each other and to
themselves, so an object met again while it is already being displayed shows as
`Name(...)`.

### 10.2 Fields and construction

Fields visibly use `var` or `const`:

```emerald
struct Vector2 {
    var x: Float
    var y: Float

    constructor(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}
```

Parameters are read-only, while fields may mutate. `self.` makes field access distinct
from locals and parameters.

The `const` rule of 4.3 applies to fields: a `const position` field holding a struct can be
neither replaced nor changed, so `self.position.x = 1` is rejected, while a `var position`
field may change. Stored nested-field assignment updates the value in place; nested
assignment through a computed property is rejected as described below.

Default field values are allowed and run in declaration order, once per construction.
They may read earlier initialized fields but not later ones, through `self.`, and may not use
`self` as a whole or call its methods or properties, since the value is still being built.
The generated constructor takes one parameter per field in declaration order; a field with a
default is an optional parameter that a call skips by naming the fields after it, as 7.3
allows for any defaulted parameter. Under a custom constructor, defaults run before its
body, so a field with a default starts out set there, and a default may read only earlier
fields that also have defaults. An explicitly supplied
generated-constructor argument replaces that field's default, which then does not run.
Every remaining field must be definitely initialized before construction completes.
Inside a constructor a `const` field is initialized exactly once: it may be set only where
no path reaching that point has already set it, and never inside a loop, which could set it
again.

A custom constructor replaces the generated constructor. A type declares at most one, since
overloading is deferred; alternative ways to build a value are type-level factory functions
such as `func Vector2.from_angle(radians: Float): Vector2`, which name their intent. A
derived constructor calls `super(...)` first when the base constructor requires arguments; a
zero-argument base call is inserted when possible. Base construction finishes before
derived field defaults and the rest of the derived constructor. Constructor delegation,
`self(...)`, is deferred with overloading: with at most one constructor per type there is no
other constructor to delegate to. When overloaded constructors arrive, `self(...)` delegates
to another constructor of the same type, must be first, cannot be combined with
`super(...)`, and may not form a cycle. A bare constructor `return` is allowed only after all fields are
initialized; constructors never return replacement values.

A fieldless type receives the ordinary generated zero-argument constructor. A subclass
without an explicit constructor receives one only when its base constructor and all
subclass fields can be initialized without arguments.

Before all fields are ready, `self` may not escape or be passed elsewhere and instance
methods may not be called. Calls to overridable methods through `self` are forbidden
throughout construction.

Primary-constructor shorthand is deferred. One explicit constructor form is sufficient
initially.

### 10.3 Properties

A property presents field-shaped access while computing or validating its value:

```emerald
const area: Float {
    return self.width * self.height
}
```

A read-only computed property uses `const` and a direct body. It runs on every read and is
not cached. A writable computed property uses `var` with explicit `get` and `set` blocks:

```emerald
var diameter: Float {
    get {
        return self.radius * 2
    }
    set {
        self.radius = value / 2
    }
}
```

The setter receives the proposed value through the read-only `value` binding. Compound
assignment evaluates the receiver and getter once, calculates the result, then invokes the
setter once. Nested mutation through a computed value is rejected rather than silently
copying and writing back. Properties should have no surprising observable side effects;
this is an API convention rather than a purity type system, with one exception the checker
can see: a getter may not change `self`, since reading a property of a `const` would
otherwise have to be rejected. A setter changes `self` exactly as a changing method does,
including 4.3's rule about reaching the value another way while it runs.

A field, a property, and a method of one type share one name space.

### 10.4 Type-level members

Type-level state and methods are supported, but the keyword `static` is removed. Call sites
make the ownership visible:

```emerald
var origin = Vector2.origin()
print(Player.count)
```

An explicit type receiver in the declaration marks a type-level member, declared inside the
braces of its own type, and the type named in front of it must be that type:

```emerald
struct Vector2 {
    var x: Int
    var y: Int

    func Vector2.origin(): Vector2 {
        return Vector2(0, 0)
    }
}

class Player {
    var Player.count = 0
}
```

This adds no keyword, is locally visible, and cannot change meaning when a method body is
edited. Type-level fields may be `var` or `const`, require initial values, and use a leading
underscore for privacy.

It is always reached through the type, including from the type's own methods, and never
through a value; an instance member is never reached through the type. A type-level
function has no `self`. Type-level members share the one name space of 10.3 with the
type's fields, properties, and methods, so a name means one thing wherever it is written.

A type-level field's annotation is optional: without one, the field holds the type of its
value, as a module-level binding does. Its value may read only the type-level fields
declared before it. Setting the fields up follows 14.1's lazy rule: once, in declaration
order, the first time the type is constructed or one of its type-level members is reached;
reaching a field that setup has not got to yet through a function is an initialization-cycle
error. Because a type-level field is one binding for the whole program, which any function
may change, 4.5 does not narrow it. Type-level computed properties are not part of the
design; a type-level function covers the same need.

### 10.5 Privacy

A leading underscore marks a private member. Privacy is enforced by the checker and does
not depend on convention alone. Public is the default; there is no `public` keyword.
`protected` is deferred.

The same rule covers every kind of member: fields, properties, methods, and type-level
functions and fields. A private member can be reached only from code written inside its
own type's braces. That includes lambdas written there, field defaults, type-level field
values, and other values of the same type, as in `other._count`. Code outside the braces
cannot reach it, even in the same file.

Privacy does not change a generated constructor's parameters: every field is still one
parameter, in declaration order. Called from outside the type, the generated constructor
may not be given a private field, so that field keeps its default and any fields after it
are passed by name. A private field with no default leaves no way to build the value
outside the type; the type then needs a constructor, or a type-level function, of its own.
Privacy limits which code can reach a member, not what a value is: equality and display
still include private fields.

Type-level visibility across directories is deferred until larger projects provide a
concrete need.

### 10.6 One braced form

Classes, structs, traits, and enums always brace their bodies:

```emerald
struct Point {
    var x: Float
    var y: Float
}

class Dog extends Animal with Speaker {
    var name: String

    func speak() {
        print("Woof")
    }
}
```

An earlier draft also allowed a block-free top-level form whose body ran to end of file,
inspired by GDScript. It is removed from the initial language and deferred (21, 24): the
reasons below are the bar a future proposal has to clear. It contradicted the formatter
contract in 18.3: the formatter would have had to either rewrite block-free types into
braced ones, making the form pointless, or maintain a second canonical output for a
*different construct entirely*
(a type body with no braces at all, not merely different brace placement — unlike 3.4's
later brace-style choice, there is no shared parsed shape the two could both normalize to).
It also added a second parsing mode, a second shape for error recovery to understand, and a
second way to teach a class declaration, in exchange for saving one brace in single-type
files. Braces already delimit every other block in the language, so the uniform rule is
both simpler to implement and easier to explain.

### 10.7 Inheritance and overriding

Classes support single inheritance: at most one base class. “Base class” and “subclass”
are the teaching terms; `super` refers to the base implementation at a call site.

Traits provide additional composition without additional class inheritance.

Overrides are explicit through `@override`:

```emerald
@override
func speak() {
    super.speak()
    print("Woof")
}
```

An override must match a real overridable base member. A same-named method without
`@override` receives a diagnostic rather than silently hiding it.

Abstract classes should be visually explicit through `@abstract`:

```emerald
@abstract
class Shape {
    @abstract
    func area(): Float
}
```

In a class, `@abstract` may also mark a bodyless method. The initial language avoids an
additional `abstract` keyword. A nonabstract subclass must implement every remaining
abstract member. Constructors are not inherited; a subclass without one receives a
zero-argument constructor only when its base and all its fields can be initialized without
arguments. An `@abstract` class cannot be constructed even when it implements every
requirement, allowing an intentionally base-only class to state that purpose explicitly.

A class shares one set of names with the classes it extends, including their fields,
type-level members, and private members, so a name means one thing on every object that
has it. Only a public method or property can be replaced, and only by one of its own kind:
an overriding method takes exactly the parameters it replaces, with the same names and
types, and gives the same type, a subclass of a class it gives, or a value that is always
present where it gives an optional of that type; an overriding property is
`var` or `const` as the one it replaces is, and holds the same type. A private member cannot
be overridden, so a constructor may call a private method once every field is set. Abstract
properties are deferred. Type-level members are not inherited: `Animal.count` is reached
through `Animal` from a subclass too.

`super.name` reaches the base class's version of a method or property, including a
property's setter through `super.name = value`, and is allowed wherever `self` is, once every
field is set. It never reaches a field, which a subclass never replaces, or an abstract
method, which has no version to run. `super(...)` may only be a constructor's first
statement. A subclass without a constructor of its own is built with no arguments.

An object runs its own class's version of each method and property, however it is reached,
and a captured method is that version. Calls through `self` are forbidden during
construction, but a base class's constructor can still pass `self` on once its own fields
are set, and the code it reaches could run a subclass's version before that subclass's
fields are. The implementation tracks how much of an object is built, base class first, and
running a version whose class's part has not begun is a runtime error rather than a read of
a field with no value. Taking a method from such an object runs nothing, so it is allowed,
and the check is made when the taken method is called.

## 11. Traits and operators

### 11.1 Trait purpose

Traits are Emerald's primary composition mechanism. They begin deliberately small:

- no stored trait state;
- method and readable-member requirements;
- default method bodies;
- explicit conformance on a class or struct;
- static checking without runtime structural guessing;
- no higher-kinded types, variance, or broad generic machinery.

Trait requirements need no `@abstract`: a signature without a body is a requirement, while
a body supplies a default. Member requirements use Emerald's existing `const` and `var`
distinction without C# getter markers:

```emerald
trait Named {
    const name: String

    func introduction(): String {
        return "I am #{self.name}."
    }
}
```

A `const` requirement promises readable access and may be satisfied by a public `const` or
`var` field or readable computed property. A `var` requirement promises reading and
assignment and therefore needs a public writable field or get/set property. A writable
member satisfies a read-only requirement, never the reverse. Neither form stores trait
state. Private members cannot satisfy public requirements.

### 11.2 Composition and conflicts

A class has one optional base class and may adopt multiple traits:

```emerald
class Duck extends Animal with Swimmer, Flyer {
}
```

Adoption is explicit: merely having matching members does not establish conformance.
Trait membership is inherited by subclasses. Traits may build on other traits with the
same `with` spelling. Structs may adopt traits but do not inherit from classes or other
structs.

An implementation supplied directly by the class wins over trait defaults. If two traits
supply the same member and the class does not resolve the conflict explicitly, the checker
reports the ambiguity and names both traits. Trait order must not silently select behavior.

Trait requirements are checked eagerly for the entire project.

Class methods, including inherited ones, outrank trait defaults. Two distinct trait
defaults with the same name require an explicit implementation; trait order never
selects one. Compatible duplicate requirements need one implementation. A writable
property requirement subsumes a read-only one of the same type; different required types
conflict. `TraitName.method(self, ...)` explicitly invokes that trait's default. Private
trait helpers may have bodies, do not become public, cannot be overridden, and do not
conflict across traits. Traits may also provide computed-property defaults.

Implementing a required method uses `@override`; a stored or computed property satisfying
a member requirement does not. Parameter names and declared defaults belong to the trait
contract, so implementations preserve the names and cannot replace defaults. An abstract
class may defer trait requirements to subclasses only when the class is explicitly marked
`@abstract`; structs must satisfy them immediately.

Using a trait as a parameter or binding type exposes only that contract and never changes
the underlying representation: a struct remains an independently copied value and a class
remains a shared reference. Equality through a trait type is deferred because the
underlying value and reference models differ.

Because a trait's value may be either, the checker treats it as a value for 4.3's rules: a
change through it needs a `var`, and a requirement changes the value whenever a struct
supplying it does. A trait has no constructor, no type-level members, and no `@abstract`; a
stored member written with a value is rejected, since a trait stores nothing. A property
supplying or replacing a trait's property never takes `@override`; a method supplying or
replacing a trait's method always does, in a struct as in a class. A conflict between traits
is reported where both are first brought together, not again in every subclass or trait
built on top. A trait's private helper is its own, and never conflicts with a type's private
member of the same name. `Trait.method(value)` may run a default that changes the value only
on an object for now, and is only ever called: taking `Trait.method` as a value is deferred,
while `value.method` takes the value's own version. A requirement's parameter defaults apply
however the implementation is reached, through its own type included. `is` tests for a trait
and narrows to it.

### 11.3 Associated types and generics boundary

Associated types and general user generics are deferred. Built-in collections may carry
element types and users may consume concrete collection types without exposing a general
generic declaration system. Any future extension must begin with real Emerald programs
that the simple trait model cannot express.

### 11.4 `Self`

`Self` has a narrow, type-relative meaning: in a struct or class member it is that declaring
type, and in a trait member it is the concrete type implementing the trait. It expresses a
parameter or result that must be that same type.

```emerald
trait Combines {
    func combine(other: Self): Self
}
```

It does not introduce F-bounded polymorphism or an unrestricted metatype system.

`Self` is written only in the parameter and result types of methods and type-level
functions, in any shape such as `List[Self]` or `Self?`; a field, a property, a local, or a
top-level function rejects it. In a struct or class it is that type. In a trait it is
whichever type adopts the trait: an implementation writes that type or `Self`, and inside
the trait's own defaults `self` is a `Self`, so a default may pass `self` to a member
taking `Self`, return it, or compare two `Self` values with `==`. On a class, a trait's
`Self` is the first class along the base chain to adopt the trait, since a subclass
inherits its methods unchanged; an abstract class adopting a trait therefore has its
subclasses take the abstract class. Through a value seen as a trait, a `Self` result is the
trait, and a member taking `Self` cannot be called, because the value could be of any
adopting type. `Trait.method(value)` cannot yet run a default whose signature mentions
`Self`.

### 11.5 Operator overloading

Operators lower to ordinary named methods so behavior remains discoverable:

```emerald
a + b       # a.add(b)
a < b       # a.compare(b) < 0
```

The overloadable set is narrow:

- arithmetic: addition, subtraction, multiplication, and division;
- ordering through one `Ordered.compare(other: Self): Int` contract;
- equality through one `Equatable.equals(other: Self): Bool` contract (8.4), with
  `Hashable.hash(): Int` alongside it for a type that also wants to be a dictionary or set
  key with its own notion of equality.

Assignment, boolean short-circuit operators, member access, calls, and language control
flow are not overloadable. Custom indexing is deferred. The existing homogeneous trait
contracts use `Self` for both operands and their result; an annotated arithmetic method may
state a different right-operand or result type.

Annotated arithmetic is an explicit registration on public instance methods of structs and
classes:

```emerald
struct Money {
    const cents: Int

    @operator("*")
    func times(quantity: Int): Money {
        return Money(self.cents * quantity)
    }
}

Money(125) * 3      # the same as Money(125).times(3)
```

The annotation takes one of those four literal symbols. Its method takes one required
parameter, has an explicit result type, and is selected using ordinary argument compatibility
(including `Int`-to-`Float` widening). A type may register several methods for one symbol only
when their parameter types are disjoint: identical types, `Int` with `Float`, and a class with
one of its subclasses overlap and are rejected at the declaration. The supported parameter
domain is nonoptional scalar types and nominal structs, enums, and classes; trait, optional,
collection, tuple, and function parameters remain deferred. This is selection among annotated
operator registrations only, not general function or method overloading.

Registrations inherit with classes. Selection sees the static type on the left: a value held as
`Animal` selects from `Animal`'s registrations even if its runtime value is a `Dog`; ordinary
virtual dispatch then runs a `Dog` override of the selected method. A subclass may add a
disjoint registration, but an `@override` inherits its base method's registration and never
repeats `@operator`. Return types do not participate in selection, so `Matrix * Vector` may
give `Vector`. `a op= b` uses the same selected operation and evaluates its destination once;
its result must be assignable back to that destination.

For a same-type operation returning the enclosing type, the method name is mandatory:
`add(other: Self): Self`, `subtract(other: Self): Self`, `multiply(other: Self): Self`, or
`divide(other: Self): Self`, matching its symbol. Conversely, each of those four names is
reserved for that exact `Self -> Self` shape when annotated. A same-type operation with a
different result, such as `Distance / Distance -> Float`, uses another name. Mixed operations
such as `Money * Int` are supported by the annotation; the left operand owns the operation and
there is no reversal, so `Int * Money` remains invalid. `Ordered` does not redefine equality —
it is `Equatable`'s own job, a separate contract entirely.

`Ordered.compare` and `Equatable.equals` remain trait contracts; `Hashable.hash` takes
nothing, since a hash is not a comparison. `/` gives what its selected method gives, not
always a `Float`. `%`, `//`, `**`, and unary `-` are not overloadable. The left operand's type
decides, and it may not be optional. Every ordering comparison in a chain runs `compare`. An
operator never changes a struct operand, so a struct method that changes `self` cannot back
one; on an object it follows the object's class, like any call. An operator on `self` is a call
through `self` under 10.2's construction rules; `a += b` is `a = a + b`.

## 12. Enums and branching

Enums are simple closed sets of explicitly named values:

```emerald
enum Direction {
    north
    east
    south
    west
}
```

Enum values have their enum type, compare for equality, print their names unless a method
provides another representation, and work naturally with exhaustive `case`. Their default
display includes the type, such as `Direction.north`. Declaration order does not create
ordering; an enum must explicitly adopt `Ordered` when its domain needs it. Enums may have
methods, computed properties, and trait conformance, but no stored instance fields.

An enum statement case that omits members and has no `else` produces a warning (6.3, 17.1).
An explicit empty `else` acknowledges intentional omission. Duplicate known alternatives are
errors.

An enum lists its values first, one name per line or separated by commas, and at least
one; a value written after a member, a stored field, a constructor, or `extends` is an
error. Each value is a `const` type-level member (10.4), so it is always written with the
enum's name, `Direction.north`, including inside the enum's own methods, and shares one set
of names with the enum's other members. An enum is never constructed, extended, or adopted,
may have type-level functions and fields, and is an eligible dictionary key (8.3).

Associated values, per-case payloads, raw integer backing controls, flags enums, and
implicit integer conversions are deferred. This keeps `enum` understandable as a closed
set before considering algebraic data types.

## 13. Errors and resources

### 13.1 Error model

Errors are ordinary typed values rooted in an `Error` class. Programs may define their own
error subclasses. Failures use `raise`:

```emerald
class InvalidScore extends Error {
}

raise InvalidScore("Score cannot be negative")
```

`Error` stores a read-only `message: String`. An error subclass whose complete stored state
is only that inherited message gets the one-argument `Error(message)` construction, so the
compact example above is complete. An error hierarchy that adds stored fields declares
ordinary constructors and begins each subclass constructor with `super(...)` as usual.
Interpreter-detected failures use
`RuntimeError`, while a failed assertion uses `AssertionError`; both are ordinary subclasses
that a typed or untyped catch may handle.

There is no `raises` annotation on function signatures. Error effects are dynamic in that
narrow sense; error values and catch bindings remain statically typed.

### 13.2 Handling

```emerald
try {
    load_game()
}
catch error: FileError {
    print(error.message)
}
finally {
    print("Finished loading")
}
```

`finally` runs whether the protected body returns, raises, or completes. A `try` may have
`finally` without `catch`. Typed catches are tested top to bottom and only the first match
runs; an untyped catch handles any `Error`. Bare `raise` inside a catch re-raises the same
value with its original failure location and is invalid elsewhere.

`return` and any `break` or `continue` that exits a `finally` are forbidden, so cleanup
cannot replace a result or suppress an error. A loop wholly inside it retains ordinary
loop control. If cleanup raises while another error is propagating, diagnostics preserve
both failures.

Unhandled errors produce Emerald stack traces containing source file, line, function, and
a concise message. Zig frames and implementation details must not appear in ordinary
diagnostics.

### 13.3 Resources

Garbage collection manages memory, not timely release of files, sockets, locks, or similar
resources. Whole-file `File` operations need no explicit resource management (15.3), while a
streamed `FileHandle` or `FileWriter` can be closed explicitly. `read()` returns all remaining
UTF-8 text and `read_line()` returns one line at a time, or `nothing` at end of file:

```emerald
var file = File.open("scores.txt")

try {
    print(file.read())
}
finally {
    file.close()
}
```

High-level helpers close automatically. A library-scoped helper can make the common
streaming case safe without adding a language keyword:

```emerald
File.with_open("scores.txt") { file =>
    print(file.read())
}

File.with_writer("scores.txt") { writer =>
    writer.write("updated scores\\n")
}
```

`with_open` and `with_writer` guarantee closure after normal completion, return, or error. A
GC fallback may close a forgotten handle eventually, but correctness must not depend on when
that happens. There is no user-visible object destructor in the initial language.

## 14. Program and project structure

### 14.1 Projects and entry points

A single file is a complete program. A directory becomes a project only when it contains
`main.em`, which `emerald new` creates. Running a file outside a project runs that file
alone, so a folder of independent exercises works as a beginner expects: `emerald run
ex1.em` never sees `ex2.em`, and two exercises that each declare `func helper` do not
collide.

Inside a project, every `.em` file under the project root is included; no imports are
needed merely to make project files exist. `main.em` is the entry file, and `emerald run
path/to/file.em` may select another entry explicitly. Until a manifest exists, the project
root is the directory containing `main.em`, independent of the terminal's working
directory. What else `emerald.toml` holds, beyond 3.4's `brace_style`, is still a roadmap
item (24).

Only the directory a file sits in is consulted, never a directory above it. `emerald run
ex1.em` in a folder of exercises sees no project even when one exists further up, which is
what keeps that layout working. The consequence is that a file in a subdirectory of a
project, run on its own, is a program on its own: it sees none of its project, and a name
it cannot find says so and names the entry to run instead.

The rewrite adopts the clearer top-level boundary suggested in the discussion:

- the entry file may contain executable top-level statements and declarations;
- other files contain declarations and initialization attached explicitly to those
  declarations;
- loading a project does not run arbitrary code from every file.

This replaces the historical prototype's “top-level statements in every file” behavior
and avoids hidden file-order or import-order effects.

A non-entry module file may declare functions and module-level bindings. The file is the
unit of initialization: it initializes once when one of its members is first accessed, and
processes bindings in declaration order. Including it or naming it in `using` does not
initialize it. Reaching a function of a file that is still initializing is not a cycle,
because declarations are hoisted and a function body runs later; reaching a binding it has
not got to yet is an initialization-cycle error. If initialization raises, later access
reports the original failure without retrying it.

Because only the entry file's top level runs, a module-level binding elsewhere has nowhere
to be assigned but its own declaration, so one without a value is rejected where it is
written.

Type-level fields follow the same lazy rule, initializing once in declaration order when
the type is first constructed or a type-level member is accessed. Merely mentioning the
type in an annotation or `using` does not initialize it.

`Program.arguments` is the provisional library name for a list of only the program
arguments, excluding the Emerald executable and entry-file paths. On the CLI, `--`
separates Emerald options from program arguments. A bare top-level `return` is allowed
only in the selected entry file and ends the program successfully after pending `finally`
blocks run. It cannot return a value; use `exit(code)` to choose a status. Unreachable
executable statements after unconditional `return`, `raise`, loop exit, or `exit()`
produce a warning, while hoisted declarations remain valid.

### 14.2 Namespaces and `using`

Directories form namespaces. Same-directory names are directly visible; another directory
is reached through its path-derived namespace:

```text
game/
  main.em
  shapes/
    circle.em       → Shapes.Circle
```

The directory is the whole of the name: the file contributes nothing to it. `circle.em`
above puts its declarations in `Shapes`, and moving a declaration from `circle.em` to a new
`square.em` beside it changes nothing that any other file writes. This settles the question
24 left open, in favor of the reading 14.3 already implies by removing filename-as-type.
Each directory becomes one namespace segment, written the way a type is written:
`ui_kit/` is `UiKit`. A directory that cannot be read as a name is reported rather than
skipped. A module-level declaration whose name is also a namespace — `struct Shapes` at the
root beside `shapes/`, or `enum Ui` in `graphics/` beside `graphics/ui/` — is an error at the
declaration, since `Shapes.Circle` would otherwise mean a member of either one.

An optional `using` declaration shortens repeated qualification:

```emerald
using Shapes
```

Aliases resolve collisions explicitly:

```emerald
using UiColor = Graphics.Color
```

`using` is file-local, imports only direct public names, and does not include or execute
files. It may appear anywhere in a file and applies to all of it, since it names no order
of execution. An alias may name either a namespace, one declaration in it, or a type nested in one (14.3). Ambiguity is
reported when a conflicting short name is used; a focused alias or fully qualified name
resolves it. A name the file's own namespace declares is never ambiguous: `using` cannot
take a name out from under the directory that declared it. Project inclusion remains
independent from `using`.

A leading underscore on a module-level declaration makes it private to that module, just
as it does for a type member. The module there is the file, so two files in one directory
may each declare `_helper` without colliding, and neither can reach the other's. Other
public same-directory declarations are directly visible, whichever file they are in and in
whatever order the files are read; names across subdirectories use their namespace unless
shortened by `using`. Two files in one directory declaring the same public name is an
error, reported against the second with the first one named.

### 14.3 File shapes

A file may declare any number of outer types, all using the braced form of 10.6. Nested
types are naming and visibility relationships only; they do not capture an enclosing class
instance. A leading underscore makes a nested type private.

```emerald
class Console {
    enum Color {
        red, green
    }

    struct Pair {
        var left: Int
        var right: Int

        func Pair.zero(): Console.Pair {
            return Console.Pair(0, 0)
        }
    }
}

const color: Console.Color = Console.Color.red
const pair = Console.Pair.zero()
```

- A `struct`, `class`, or `enum` body may declare nested `struct`, `class`, `enum`, and
  `trait` types, to any depth the parser's nesting limit allows. A trait's body holds
  requirements and defaults, so it may not declare one. An enum's nested types come after
  its values, like every other enum member (12).
- A nested type is declared with its bare name. It is a type-level member of the type around
  it, so it shares that type's one member name space (10.3, 10.4), and it is always reached
  through that type, `Console.Color`, including from the enclosing type's own methods and
  from inside the nested type itself. A type-level member of a nested type names that type
  bare where it is declared, as the nested type itself is declared: `func Pair.zero()` inside
  `Pair`, used as `Console.Pair.zero()`.
- A path through a directory namespace comes first: `Ui.Console.Color`. `using` still takes
  only namespaces, but an alias may name a nested type, `using Color = Console.Color`.
- A nested type displays with the types around it but without its directory namespace,
  `Console.Color.red`: the nesting is part of the type's name, while the namespace is where
  its file lives.
- 10.5's braces rule is unchanged, which settles privacy in both directions: a nested type's
  code is written inside its enclosing type's braces and so reaches that type's private
  members, while the enclosing type's code is not inside the nested type's braces. A private
  nested type is reachable only inside its enclosing type's braces, as a value or as a type.
- `Self` in a nested type's method means the nested type. A nested type is not inherited: a
  subclass reaches it through the class that declares it (`Animal.Tag`, not `Dog.Tag`).
- Reaching a nested type's type-level member sets up that nested type's type-level fields
  (14.1), not its enclosing type's.
- A module-level declaration may not share its name with a directory namespace (14.2), so a
  path such as `Shapes.Circle` never means a type member and a namespace member at once.

The old filename-as-implicit-type rule is not assumed. Type declarations state their own
names so search, rename, and diagnostics remain direct.

### 14.4 Packages and foreign code

External packages and a package manager are deferred until there is a stable language and
runtime. A future `emerald.toml` appears only when a project needs configuration,
dependencies, distribution metadata, or nondefault warning policy.

C compatibility belongs behind explicit library bindings. Foreign values do not weaken
Emerald's static rules, optional rules, ownership model, or naming diagnostics. The C ABI
is the first interoperability target because it is portable across Zig and future native
backends.

## 15. Standard library organization

### 15.1 Philosophy

The settled library principle is:

> A small essential vocabulary plus a rich standard vocabulary. Beginners learn the first
> dozen operations; experienced developers discover the rest through completion.

Methods live on values when they are naturally discovered from that value. Cohesive
operations without one natural receiver live in named modules. Prelude functions are
reserved for universal, frequent actions.

The old `Kernel` name is not carried forward. `input`, `print`, `write`, `random`, and
process-exit behavior are described as prelude functions even if the implementation stores
them in an internal namespace.

New convenience methods should meet at least one of these tests:

1. It replaces awkward syntax or a common error-prone pattern.
2. Correct implementation requires Unicode, numeric, platform, or runtime knowledge users
   should not reproduce.
3. It is established vocabulary across several relevant languages.
4. It has repeated naturally in actual Emerald programs.
5. It has clear educational value at very low semantic cost; such exceptions are recorded
   honestly.

`gcd`, `lcm`, `factorial`, `multiple_of?`, and `digits` are accepted educational
conveniences. Ruby is a source of inspiration, while clearer names from Kotlin, Python,
C#, Swift, or common practice win when Ruby abbreviates or overloads a word.

A simple `Textual` trait with `to_string(): String` controls deliberate user-facing display
in printing and interpolation, with structs, classes, and enums that omit it retaining a
useful field-based debug representation; enums that omit it default to their qualified
names. It is a prelude trait in 11.5's family, adopted explicitly like every other: a method
named `to_string` alone changes no display, and the checker warns when a type declares one
without adopting the trait.

An adopting value renders through its own `to_string()` wherever it appears, nested in a
collection or another type's debug form included, because the display walk carries the
resolution with it. What the trait replaces is a value's own rendering and never how a
container frames it, so an adopting value is not quoted the way a nested `String` is.
`to_string()` is ordinary code: a raise propagates from the `print` or interpolation that
ran it and is catchable there, with no partial line written, and a value that reaches itself
shows `Name(...)` at the repeat under the same guard the debug form uses. Diagnostics —
assertion failures and runtime error text — deliberately keep the field-based form, so
building a failure never runs the program's own code. Display customization must not alter
equality or identity once built.

### 15.2 Prelude

Initial bare functions include:

```text
input, input_maybe, print, write, random, exit
```

The prelude also declares `Ordered`, section 11.5's comparison trait. Like the functions, it
is visible bare in every file, and a program's own declaration of the same name takes the
name's place in the files that see it.

`input(prompt)` writes the optional prompt, reads one line, removes its line ending while
preserving other whitespace, and returns `String`. Pressing Enter returns `""`; end of
input raises `InputError`. `input_maybe(prompt)` instead returns `nothing` at end of input.
A line that is not valid UTF-8 also raises, so every `String` holds Unicode text.

`print` and `write` accept zero or more ordinary values through their display
representation. Multiple arguments evaluate left to right and are separated by one space.
A string displays as its text. Inside a collection it displays quoted, with escapes where
needed, so `["a, b"]` and `["a", "b"]` cannot be mistaken for each other.
`print` appends a newline; `write` does not. Separator customization is deferred, and
interpolation remains the primary way to construct deliberate prose.

`exit()` ends the program successfully; `exit(code)` uses a process status from `0` through
`255`. Other status values are diagnosed. `exit` unwinds pending `finally` blocks but is not
caught as an error.
Reaching the end of the entry file exits successfully; an uncaught error uses a nonzero
status.

### 15.3 Files, directories, and paths

`File`, `Directory`, and `Path` provide whole-file UTF-8 text operations, directory work,
and lexical path manipulation:

```emerald
File.read(path)
File.read_binary(path)
File.open(path)
File.with_open(path, block)
File.create(path)
File.with_writer(path, block)
File.write(path, contents)
File.write_binary(path, bytes)
File.append(path, contents)
File.read_lines(path)
File.write_lines(path, lines)
File.exists?(path)
File.copy(source, destination)
File.move(source, destination)
File.delete(path)

Directory.exists?(path)
Directory.create(path)
Directory.delete(path)
Directory.delete_recursive(path)

Directory.list(path)

Path.join(parts)
Path.name(path)
Path.stem(path)
Path.extension(path)
Path.parent(path)
Path.absolute?(path)
Path.absolute(path)
```

`File.exists?` and `Directory.exists?` are mutually exclusive for real paths; there are no
redundant classification predicates. `Directory.create` creates parents as needed and succeeds
when the directory already exists. `Directory.delete` removes only empty directories. `list`
returns unsorted full paths for files and subdirectories together. `Path.join` accepts a
`List[String]`; `extension` omits its dot and `parent` returns `""` when there is none.

Whole-file helpers close their handles automatically. `File.open` returns a read-only
`FileHandle`; its `read()` returns the remaining text, `read_line()` returns the next line as
`String?`, and `close()` is idempotent. `File.create` returns a write-only `FileWriter`,
truncating or creating its path; `write(text)` streams UTF-8 text and `close()` is idempotent.
`read_line()` follows `read_lines` exactly: a trailing newline produces no extra line, while a
final unterminated line is still returned. `with_open` and `with_writer` close their resource
after normal completion, return, or error. `read`, `read_lines`, `write`, `write_lines`,
`append`, FileHandle reads, and FileWriter writes are UTF-8 text only; `write_lines` writes a
newline after every line. `Path.absolute` is the one Path operation that consults the
filesystem.

Every operation other than the two predicates raises `FileError` for missing paths, access
failures, invalid UTF-8, and failed writes; reading a closed FileHandle also raises
`FileError`. `Bytes` is immutable raw binary data: `Bytes.from_list(List[Int])` builds values
from 0 through 255, `String.to_bytes()` converts valid text, and `Bytes.to_string()`/`to_string_maybe()`
convert only valid UTF-8. Bytes supports `count`, byte indexing, slicing, equality, concatenation,
and dictionary/set keys. FileHandle also offers `read_bytes(count): Bytes?` and
`read_all_bytes(): Bytes`; FileWriter offers `write_bytes(bytes)`. More-specific filesystem error
subclasses remain deferred.

### 15.4 Regular expressions

Regular expressions are a standard-library roadmap facility, not part of the first
interpreter milestone, new literal syntax, or a macro. Raw single-quoted strings keep
patterns readable. The intended focused API is:

```emerald
var digits = Regex('\d+')

digits.matches?(text)                    # entire string
digits.contains_match?(text)
digits.find(text)                        # optional Match
digits.find_all(text)                    # list of Match
digits.replace(text, replacement)        # first match
digits.replace_all(text, replacement)
digits.split(text)
```

Construction validates the pattern and raises a `RegexError` with the location inside the
pattern. A `Match` exposes at least `text`, `start`, and `end`; capture groups remain a
later addition. Literal string methods never interpret their argument as a pattern. The
implementation may wrap a proven C library, but Emerald owns the Unicode behavior, API,
and diagnostics.

### 15.5 Formatting

String interpolation handles ordinary formatting. A simple explicit formatting facility
may cover reusable templates and numeric presentation, but it should not become a second
mini-language prematurely.

Numbers use readable named arguments rather than compact format codes. `Int.to_string` takes
a named, defaulted `base`, and both `Int` and `Float` have a `format()` (see
[docs/library/int.md](library/int.md) and [docs/library/float.md](library/float.md) for the
full pages):

```emerald
12.5.format(decimal_places: 2)       # "12.50"
1234567.format(group_digits: true)   # "1,234,567"
255.to_string(base: 16)              # "ff"
255.to_string(base: 2)               # "11111111"
```

`format()` returns a `String`; `round_to()` changes a numeric value. Default formatting is
locale-independent. Locale-aware formatting is a separate later facility. Infinity and
NaN render plainly as `"Infinity"` and `"NaN"`, ignoring `format`'s arguments, and are exposed
as type-level `Float` constants.

Dates, time zones, durations, serialization, networking, and concurrency belong in later
standard-library passes. Their absence must not be patched with premature general-purpose
generics.

## 16. Annotations, assertions, and tests

### 16.1 Annotations

Annotations use the `@name` surface and attach declarative metadata to the declaration
below them. They do not rewrite arbitrary user code.

The clean initial set is intentionally small:

- `@test` marks a test function;
- `@override` confirms an inherited override;
- `@abstract` marks an abstract class or a bodyless abstract class method. Trait
  requirements are already identified by their missing bodies and do not use it.
- `@operator("+")`, `@operator("-")`, `@operator("*")`, or `@operator("/")`
  registers a public instance method of a struct or class for that arithmetic symbol
  (11.5).

Interop-specific annotations such as the former `.NET`-oriented `@export`, `@mirrors`,
and emitted-name controls are not carried forward automatically. Add a portable annotation
only when the C boundary or another backend demonstrates the need.

Unknown annotations are errors with spelling suggestions. Annotation arguments, where
allowed, must be compile-time literals or other deliberately supported constants. User
defined annotations and macros are deferred.

### 16.2 `assert`

`assert` is a compiler-known statement rather than a macro or ordinary function. It can
observe the condition's syntax and evaluated operands without evaluating either side
twice:

```emerald
assert clamp(15, 0, 10) == 10
```

A failure reports the source expression, relevant actual values, and location. It raises a
test/assertion error that normal test reporting understands.

Assertions remain active in ordinary and optimized builds. An optional message may explain
the expectation, separated from the condition by a comma: `assert score > 0, "score must be
positive"`. Equality assertions show both operands while evaluating each exactly once.

`check` is not a second assertion spelling. One clear construct is enough.

### 16.3 Test discovery

`emerald test` discovers functions marked `@test`. A test accepts no parameters and
produces no result. Tests use ordinary Emerald code and `assert`; there is no separate
testing language. A filename convention such as `*_test.em` remains a tooling question,
not an additional discovery requirement.

Test loading checks project declarations without running the application's top-level entry
statements. Tests run independently enough that one failure can be reported without hiding
the remainder. Ordering should be deterministic, and test output should identify the file,
test name, failure expression, and stack trace.

Entry-file types and functions remain visible to tests under the ordinary namespace rules.
In test mode, an entry-file binding initializer is lazy and runs only if a test reaches
that binding, using the same initialize-once and cycle rules as a module binding. Other
entry-file statements never run. This lets tests reuse declarations without starting the
application while preserving explicit side effects when a test deliberately accesses
initialized program state.

Filtering tests by a name or path is useful tooling and does not require language syntax.

## 17. Diagnostics

### 17.1 Default shape

Diagnostics are concise by default and answer four questions:

1. Where is the problem?
2. What did the compiler understand?
3. Why is that invalid?
4. What concrete correction is likely?

```text
main.em:7:9: `score` may not have been assigned
  print(score)
        ^^^^^
Assign `score` on every branch before reading it.
```

Locations include file, line, and useful column spans. The lexer, parser, checker, lowering,
interpreter, and future backends preserve source spans rather than reconstructing them.

Every diagnostic has a severity, error or warning. An error stops checking, and, before a
program runs, being reached at all; a warning renders with a `warning: ` marker after the
location but is otherwise the same four-part shape, and does not stop checking or execution.
`emerald check`/`run`/`test` still exit `1` (18.1) when only warnings were found, once
nothing more specific (a runtime failure, a test failure) took priority, so a warning is
never silently missed, but the checked program still runs. Warnings currently reported: a
nonexhaustive statement `case` with a coverable subject (6.3, 12); an `is` test already known
to be true (4.4); and code after a statement that can never complete, such as after
`return` (6.5).

### 17.2 Pedagogical behavior

- Prefer the user's vocabulary over implementation terminology.
- Never expose Zig types, stack frames, allocation details, or parser-internal names.
- Detect common mistakes such as `=` in a condition and explain `==` directly.
- Suggest close spellings for names, methods, types, and annotations.
- Show one primary error clearly, then related notes; avoid cascades caused by the first
  parse or type failure.
- Warnings should be scarce enough to be read.
- Errors and warning text receive behavioral tests.

Because braces determine scope, indentation remains nonsemantic. The checker warns only
when indentation strongly depicts a different brace scope—for example, a line visually
nested beneath a statement that opened no block. The warning explains the scope the parser
actually used and offers the formatter's indentation. Ordinary personal spacing does not
produce semantic warnings.

`emerald explain <diagnostic-code>` expands a diagnostic into a short worked example. The
initial catalog is intentionally small: only diagnostics with a stable code in their CLI
rendering have an explanation, so a code is a maintained teaching promise rather than noise
on every problem. Bare `emerald explain` is deferred: a one-shot command has no trustworthy
"most recent diagnostic" without a separately designed persistence model. An explicit code
works in CI, documentation, and shared troubleshooting.

If the catalog grows beyond a small hand-maintained set, its code, title, explanation, and
example move into one typed registry that drives both the command and generated reference
documentation. That synchronization work is deferred until the catalog supplies a concrete
reason to build it.

An eventual `emerald.toml` may adjust warning levels. Defaults remain simple and
instructional.

## 18. Command-line and editor tooling

### 18.1 Initial CLI

One `emerald` executable provides full-word commands. Bare `emerald` and `emerald --help`
print a short discovery banner; `emerald help <command>` and `emerald <command> --help` give
the command's own usage. Implemented user-facing commands (`src/main.zig`'s `Command` enum):

```text
emerald run
emerald check
emerald test
emerald format
emerald repl
emerald explain
emerald help
```

`emerald lsp` is also implemented, but is intentionally absent from that discovery banner:
it is a standard-input/output protocol endpoint for editors, not an interactive terminal
workflow. `emerald help lsp` documents its optional `--stdio` spelling.

`emerald new` is not implemented; it reports an unknown command and exits `64`. It belongs with
`build`, `debug`, and package `add` (18.1.1) as later tooling, not the settled command set.

`emerald --version` prints the version embedded in the binary. Development builds currently
print `Emerald 0.6.0-dev`; release automation derives a release build's value from its `vX.Y.Z`
tag, so the tagged `v0.4.0` binary prints `Emerald 0.4.0`.

There is no `fmt` alias. `run` checks the complete project before executing; `check`
performs the same analysis without initializing modules or executing user code. This is
useful when a program would prompt, open a window, modify files, or run indefinitely.

`emerald run <file.em> -- <program-argument>...` and `emerald test <file.em> --
<program-argument>...` hand everything after `--` to the program as 14.1's
`Program.arguments`, never to Emerald itself. `check` deliberately accepts only a file:
because it does not run a program, accepting arguments it cannot use would be misleading.
Without `--`, `Program.arguments` is `[]`.

A machine-readable `--diagnostic-format=json` flag is a later-tooling design, not yet
implemented (no diagnostic-producing command accepts it today). The design to build
toward: an initial versioned JSON object containing a schema version and a diagnostics
list; each diagnostic includes its stable code, severity, message, source path, byte span,
one-based display line and Unicode-scalar column, related notes, and machine-applicable
fixes when available. Machine mode writes only that object to standard output. The LSP
adapter converts canonical source spans to the position encoding negotiated with the
editor.

Process statuses are stable: `0` means success, `1` means source or formatting diagnostics,
`2` means an uncaught runtime error, `3` means tests completed with failures, `64` means
invalid command usage, `66` means the named file could not be read (missing, unreadable, or
similar — a problem with what was named, not with how the command was typed), and `70` means
an internal Emerald failure. `64`/`66`/`70` are BSD `sysexits.h`'s own
`EX_USAGE`/`EX_NOINPUT`/`EX_SOFTWARE`. An explicit `exit(code)` from a running program uses
the requested valid code.

The initial test runner prints `N tests passed.` when all tests pass, or
`N tests, F failed.` after running the complete discovered set. Assertion failures identify
the test function in their diagnostic, and test failures use status 3.

### 18.1.1 Documentation source

The repository's `docs/language/` and `docs/library/` Markdown trees are the canonical
programmer-facing language guide and standard-library reference. They live with the language
implementation, examples, and conformance programs so a change to behavior updates its
explanation in the same review. A future documentation site may consume these sources, but
site presentation, search, and deployment do not become a second semantic authority.

Reference entries state their callable shape, result, and edge behavior. They explicitly mark
changing operations, optional results, callbacks, and value-dependent runtime failures.
Runnable examples link to repository examples or conformance programs; documentation tooling
eventually verifies those links and examples automatically.

`build`, `debug`, package `add`, and a distribution command are later tooling. Names should
describe user goals in full words.

Commands use stable nonzero exit codes for source errors, runtime errors, test failures,
tool misuse, and internal compiler failures. The exact table belongs in the CLI contract.

### 18.2 New projects and manifests

`emerald new` is not implemented yet (18.1). The settled design:

```text
emerald new guessing_game
```

creates a directory with a readable `main.em` and no mandatory manifest. A manifest named
`emerald.toml` appears only when configuration, dependencies, distribution, or warning
policy requires it. Build configuration is data, not executable Emerald code. Its first
real key, `brace_style` (3.4), exists for exactly that reason: a project reads it once, and
everything else it might eventually hold remains open.

### 18.3 Formatter

`emerald format` has one canonical output per project, with exactly one configuration
axis: `emerald.toml`'s `brace_style` (3.4) picks Stroustrup (the default) or Allman, and
every file in the project is normalized to that one choice. Beyond that one axis there is
no further style configuration. The formatter applies indentation, spacing, final
newlines, and comment-preserving rules the same way regardless of brace style. It must
understand tokens so braces inside strings and interpolation do not affect indentation.

The formatter refuses to rewrite a file it cannot parse safely. Block-comment interiors
retain deliberate diagrams and formatting. Format-on-save uses the same implementation as
the CLI.

Settled by the first implementation slice, and binding on any future backend that formats:

- Indentation is four spaces; there are no tabs anywhere in canonical output.
- An empty body stays on its header's line as `{ }` in either brace style:
  `class InvalidScore extends Error { }`, `else { }`. A body with content, or with only a
  comment, opens onto its own lines.
- A run of blank lines between two statements, type members, or `case` arms is collapsed
  to exactly one; a block never opens or closes on a blank line.
- Line breaks the author already chose inside one statement or expression are preserved
  rather than reflowed to a canonical width: this is a normalizer in the manner of gofmt,
  not a full pretty-printing engine, and no line width is invented, since none is settled
  here. Whether a call's arguments, or a list, dictionary, or tuple literal's elements,
  already span more than one line decides one-line versus one-item-per-line layout: a
  literal gains a trailing comma in the one-item-per-line form, since its grammar accepts
  one; a call's argument list does not, since its grammar does not.
- A comment on the same source line as the statement before it stays on that line rather
  than becoming the next statement's leading comment. An ordinary `#` or `##` comment is
  reindented to its new position; a `#[ ... ]#` block comment's interior is reproduced
  byte for byte, undisturbed, so a deliberate diagram survives.
- Every number, string, and interpolation literal is copied verbatim from its source span
  rather than reprinted from its checked, escape-cooked value. A triple-quoted string's
  written indentation therefore survives untouched, and code written inside `#{ ... }` is
  not itself reformatted in this slice.
- Grouping parentheses are never preserved as written, since parsing erases the difference
  between a parenthesized expression and its unwrapped equivalent; the formatter always
  re-derives which parentheses are load-bearing from section 5.3's precedence and
  associativity, adding or dropping them accordingly. `(-9223372036854775808)` is one
  narrow exception that keeps its parentheses before `.`, `(`, or `[`: section 5.3 reads
  the minimum `Int`'s magnitude as one token with `parseUnary`, which never hands it to
  `parsePostfix`, so it cannot take a member, call, or index directly the way every other
  literal can.
- `emerald format <path>` is project-aware exactly like `check` and `run` (14.1): it
  formats every file of whatever project `path` names, not only `path` itself. `--check`
  prints every file that would change, followed by the command that applies those changes;
  it exits `1` (18.1's status shared with source diagnostics) if any would, without writing
  any of them. A formatting run is silent when every file was already canonical and otherwise
  reports the number of files it formatted.

### 18.4 REPL

`emerald repl` keeps declarations and values across entries. A bare expression prints its
value; a statement follows normal statement behavior. Multiline input continues while a
delimiter or declaration body remains incomplete.

The REPL keeps ordinary binding rules: a `var` may be reassigned, while a name may not be
redeclared and a `const` may not be replaced. `:help` lists its three commands, `:reset`
clears the session, and `:quit` exits. An invalid entry does not partially mutate the session.

### 18.5 Language server

The LSP server reuses the compiler's lexer, parser, resolver, and type checker. It does not
maintain a second parser or approximate type system.

The first slice (`src/Lsp.zig`) implements what already reuses the compiler almost
unchanged:

- live diagnostics;
- document symbols;
- format on save.

The second slice is complete: hover, go to definition, find references, rename (with
`prepareRename`), and completion, in that order, each building on what came before.

Inferred-type hover needed two things the first slice's file-scoped features never did:
`Checker.zig`'s `expression_types` (every expression's type, by expression — `analyzeProject`
in `src/emerald.zig` exposes checking's full detail without executing anything) and a
document's whole project (14.1), since a file checked alone sees none of its own project's
other declarations. `Lsp.zig`'s `loadDocument` reads a document's project from disk,
substituting the editor's own buffer for the open file — the one exception to the first
slice's "never touches disk," needed because hover and everything after it have to see
beyond one file to be useful for a real, multi-file program. Diagnostics publishing was
upgraded the same way, fixing a latent gap: previously, opening one file of a multi-file
project showed false "not defined" errors for anything it referenced from a sibling file.

Go to definition and find references share hover's foundation plus a name-to-declaration
index the resolver's existing hoisting pass now also records. Rename is find references' own
result set (the declaration included), each site's span replaced by the new name;
`prepareRename` reuses that same result set to answer with whichever site contains the
cursor, rather than a separate word-boundary guess of its own. Completion needed a materially
different strategy from the rest: a broken construct like `foo.` fails to *parse* at all,
discarding its whole enclosing statement, so a completion request patches a throwaway copy of
the buffer (`foo.` becomes a synthetic call) rather than changing the shared parser's recovery
for every caller. It is scoped to a value's own member access; a type-qualified base's own
members (10.4), namespace-level completion, and a bare identifier with no preceding dot
remain open.

Quick fixes correspond to known diagnostics and deterministic edits, and are not yet
implemented. The official VS Code extension comes first, while the server remains
editor-independent.

### 18.6 Debugging

Preserve runtime hooks and source spans for a later Debug Adapter Protocol server. Initial
debugging should support breakpoints, step in/over/out, call stacks, locals, and expression
evaluation in `.em` source. The same debugger core should serve the CLI and editors.

## 19. Zig implementation architecture

### 19.1 Toolchain discipline

- The initial toolchain is pinned to Zig `0.16.0` in the repository. CI uses the same
  version, and upgrades never track `master` implicitly.
- Keep that release's standard-library source locally searchable through the paths reported
  by `zig env`.
- Treat compiling probes and the pinned standard-library declarations as authoritative for
  Zig APIs.
- Upgrade intentionally in a dedicated compatibility change that runs all probes and
  Emerald tests.
- Prefer a conservative Zig subset: structs, tagged unions, slices, explicit allocators,
  error unions, and straightforward standard-library containers.
- Introduce `comptime`, reflection, or generic helpers only for a concrete implementation
  need and only after a compiled probe establishes the exact behavior.

When a Zig behavior is uncertain, write a minimal program under an
`implementation-probes` directory, compile it with the pinned toolchain, and record the
result. If a pattern cannot be pointed to in the pinned source or demonstrated compiling,
it is not accepted implementation knowledge.

**Unicode is Emerald's dependency, not Zig's.** Inspection of the pinned `0.16.0` standard
library confirms `std.unicode` provides UTF-8 and UTF-16 encoding, decoding, validation, and
code-point counting, and nothing more: there is no grapheme cluster segmentation and no
normalization. Grapheme indexing from 9.1 needs UAX #29 and normalized equality from 9.2
needs UAX #15, so Emerald vendors the required Unicode tables with a recorded Unicode
version, regenerates them deliberately, and owns the segmentation and normalization code.
`std.fmt` does supply shortest-round-trip float formatting, which satisfies the display
rule in 9.4.

The tables currently follow **Unicode 17.0.0**. `tools/unicode/fetch.sh` downloads the
database, `tools/unicode/generate.zig` writes `src/unicode/tables.zig`, and
`zig build unicode-conformance` checks the result against the whole of Unicode's
NormalizationTest.txt. The routine test suite embeds GraphemeBreakTest.txt and every part
of NormalizationTest.txt except the character-by-character part. The same tables supply
identifier characters (3.3), whitespace, and full case mapping.

### 19.2 Frontend pipeline

The initial architecture is:

```text
source manager
    → lexer
    → parser
    → syntax tree
    → name resolution
    → type checking and flow analysis
    → tree-walking interpreter
```

Stages communicate through explicit data structures. The syntax tree does not contain
Zig runtime values, and semantic types do not depend on the interpreter. This keeps a
future bytecode, C-emitting, LLVM, or other backend replaceable.

Tools that execute generated or otherwise untrusted programs may set an interpreter step
budget. It decrements at every statement and expression, and exhaustion stops the run at
the host boundary rather than as a catchable Emerald error; this is a tooling resource limit,
not ordinary language behavior or a program-configurable execution timeout. The deterministic
fuzz runner uses it with discarded output, so execution-level fuzzing cannot hang or retain
unbounded output even as its generator gains loops.

### 19.3 Source model

Every token and syntax node carries a source span into an immutable source-file record.
Diagnostics, stack traces, formatter integration, LSP navigation, assertions, and future
debugging all consume the same span model.

Identifiers should be interned only when measurement or implementation simplicity
justifies it. The first version may use explicit strings and maps if that makes correctness
easier to inspect.

### 19.4 Allocation domains

Keep allocation purposes explicit:

```text
source storage       files and stable source text
syntax arena         tokens and syntax nodes
semantic arena       symbols and types
scratch allocation   temporary formatting and analysis
Emerald heap         runtime objects traced by the GC
```

Bounded frontend phases may use arenas owned by the compilation session. Critical
subsystem and runtime boundaries receive explicit Zig allocator values or owned allocator
fields so the code reveals which lifetime is intended. Allocator choice stays out of
Emerald's language semantics.

### 19.5 Runtime values and garbage collection

The interpreter begins with a tagged runtime value representation for immediate values and
references to managed objects. Emerald programmers do not allocate or free ordinary
objects manually.

The first collector is a custom, nonmoving, stop-the-world mark-and-sweep collector. It is
deliberately simple and unoptimized. Likely managed objects include strings where not
represented immediately, lists, dictionaries, sets, class instances, closures, captured
environments, and error objects.

Roots include:

- active interpreter stack frames and locals;
- module and type-level variables;
- closure environments reachable from those values;
- temporary values held across an allocation or call;
- host handles that deliberately retain an Emerald value.

No hidden pointer may silently keep an object alive. Holding a managed object must be an
explicit act, and the set of roots must follow from those acts rather than from what
happens to be on the host stack.

The interpreter satisfies this by deriving the roots from its reference counts rather than
by registering each temporary in a root API. Every holder retains, counts may be too high
but never too low, and so an object held from outside the heap has a count that no other
managed object accounts for. Tallying the references that come from managed objects and
comparing against the count finds exactly the external holders: module variables, the scope
stack, and every value in flight. The reason to prefer this over a registration API is the
failure mode. A missed registration frees an object still in use; a count that is too high
only keeps a dead object alive, so the worst outcome is the leak the collector exists to
reduce rather than memory corruption.

Collection may initially occur at predictable allocation thresholds. The collector does
not move objects, finalize resources, expose manual collection to ordinary Emerald code,
or attempt concurrency. Weak references, generations, compaction, concurrent marking, and
precise performance tuning are deferred.

### 19.6 Runtime and backend boundary

Define language semantics once in backend-neutral tests. Arithmetic, equality, ordering,
Unicode, closure capture, initialization, exceptions, and evaluation order are common
places for a backend to inherit its host's wrong behavior.

The interpreter is the first executable specification, supported by conformance programs.
A future backend is acceptable only when it passes the same programs without changing
expected output or diagnostics where the phase is shared.

The runtime may expose a C ABI internally for portability, but Emerald-facing wrappers own
types, errors, and names. A backend switch should preserve source, tests, syntax trees,
semantic rules, and public library contracts.

## 20. Implementation sequence

The rewrite should advance through small vertical slices:

1. **Repository and pinned Zig toolchain** — version record, build command, one passing
   program, and one compiled Zig probe.
2. **Source manager and diagnostics** — load UTF-8, retain spans, print one excellent error.
3. **Lexer slice** — identifiers, integers, strings, comments, newline, and EOF.
4. **Expression slice** — parse and evaluate integer arithmetic with precedence.
5. **Statement slice** — `var`, assignment, `print`, blocks, and `if`.
6. **Static checker slice** — inferred locals, annotations, definite assignment, and
   operand errors before execution.
7. **Functions slice** — calls, returns, scopes, recursion, and stack traces.
8. **Collection slice** — list literal, indexing, mutation, and one higher-order method.
9. **Callable slice** — lambdas, closures over captured scopes, function values, and the
   trailing-block call form.
10. **Managed heap slice** — the simple collector, with roots derived from reference counts
    per 19.5 rather than a registration API. Reference counting reclaims everything the
    earlier slices can build; a closure and the scope it captured can point at each other,
    and that cycle is what needs collecting.
11. **Project slice** — `main.em`, multiple files, namespaces, and `using`.
12. **Object model** — structs, classes, construction, properties, inheritance, traits,
    operators, and enums in dependency order.
13. **Errors and tests** — typed errors, `raise`, `try`/`catch`/`finally`, `assert`, and
    `emerald test`.
14. **Standard-library growth** — add methods only alongside behavioral tests and examples.
15. **Tooling** — canonical formatter, REPL, LSP, then debugger protocol.
16. **Test infrastructure and hardening** — automate the existing Debug and ReleaseSafe
    suites in CI with the pinned Zig version; add allocator-failure testing for ownership
    paths; fuzz malformed lexer and parser input; bring the full Unicode conformance data
    into the automated test path; run the portable suite on Linux, macOS, and Windows; add
    focused subsystem tests where end-to-end failures are difficult to localize; and expand
    errors and test-runner coverage across nested handlers, inheritance, and multi-file
    projects. The slice is complete when failures in each layer are caught automatically
    and every supported host has a repeatable test result.

Each slice ends with a runnable Emerald example and behavioral tests. Do not scaffold every
future subsystem before the first expression runs.

## 21. Deferred features

The following are deliberately outside the initial implementation:

- broad user-declared generics;
- a source-visible `Any` top type;
- immutable collection views and collection covariance;
- function and method overloading, and with it overloaded constructors and constructor
  delegation through `self(...)`;
- braceless type bodies, a file-scoped form whose body runs to end of file (10.6);
- nested optionals;
- variadic functions;
- `protected` and type-level visibility controls;
- enum payloads and algebraic pattern matching;
- general user-defined `Iterable` and `for` integration;
- a package registry and package manager;
- concurrency, async, and parallel execution;
- user-defined macros and advanced annotations;
- runtime metaprogramming;
- primary constructors;
- implicit destructors and deterministic finalization syntax;
- weak references, generational, moving, or concurrent GC;
- an optimizing native compiler;
- broad automatic foreign-library exposure.

Deferred means the design leaves room without reserving unnecessary syntax. A future
feature still has to justify itself.

Concurrency is the nearest major post-runtime design pass: consider it after the
single-threaded interpreter and core runtime stabilize, before packages or advanced
metaprogramming. Native libraries may use threads internally, but Emerald callbacks obey
the single-threaded language model until that pass defines otherwise.

## 22. Reconstruction decisions and history

### Full-conversation recovery

The complete exported design conversation was recovered and audited after the first
compact reconstruction. It confirms that the following were explicit decisions rather
than provisional guesses:

- failures use `raise`, with bare re-raise inside `catch`;
- only the selected entry file executes arbitrary top-level statements;
- resources support explicit `close`, `finally`, and library-managed helpers, while GC
  manages object memory and only provides eventual resource fallback;
- type-level declarations use an explicit type receiver such as
  `func Vector2.origin()`;
- ordinary calls require parentheses, while trailing lambdas may occupy the final argument
  position without empty parentheses;
- read-only computed properties use a direct `const` body, while writable properties use
  `var` with `get` and `set`;
- trait requirements omit `@abstract` and use `const` for readable access or `var` for
  readable and writable access; and
- the initial CLI includes `run`, `check`, `test`, `format`, `repl`, `new`, `explain`, and
  `help`.

### Confirmed departures from the historical prototype

These newer decisions supersede the existing C# implementation and old design document:

| Area | Historical prototype | Zig rewrite |
| --- | --- | --- |
| Host | C#/.NET with a planned CIL backend | Zig interpreter with replaceable backend boundaries |
| Constants | `SCREAMING_SNAKE_CASE` | `snake_case` |
| Struct mutation | Structs were immutable | Struct fields may mutate through a `var`; `const` freezes the value |
| String indexing | No integer indexing | Zero-based grapheme indexing |
| Optional type spelling | `T?` | `T?` retained |
| Overloading | Supported | Deferred; names are unique within a scope |
| Type declaration bodies | Braced, plus a block-free to-EOF form | Braced only |
| `Int` width | Unstated | 64-bit signed, checked overflow |
| String normalization | Unstated | At comparison; construction preserves bytes |
| `Self` | Deferred | Narrowly supported in method signatures of traits and types |
| User `Iterable` | Implemented | Deferred and retained on the roadmap |
| `case`/`when` | Deferred | Accepted with a controlled initial matching model |
| `finally` | Deliberately absent | Accepted |
| `!` methods | Rejected wholesale | Marks an in-place counterpart to a value-producing plain method |
| Console input | `read_line` | `input` |
| Return types | `:` | `:` retained |
| Lambdas | `=>` | `=>` retained; `->` rejected |
| Formatter command | `fmt` | `format` |
| Macros/annotations | Accumulated .NET-oriented set | Restarted from a minimal portable set |

### Reconstruction corrections already applied

The first compact reconstruction was too aggressive. Subsequent review corrected it in
place:

- ordinary calls require parentheses, with trailing lambdas as the explicit final-argument
  exception;
- inline `if` expressions are supported;
- block and one-line guard forms of `unless` are both supported, without `else` (since
  superseded: `unless` is removed, and trailing `if` is the guard form);
- string indexing itself is allowed and operates on grapheme units;
- explicit resource closing is confirmed while GC is only a fallback;
- constants and enum values use `snake_case`;
- return annotations use `:` and lambdas use `=>`;
- optional chaining was first deferred during reconstruction and was later restored as
  `?.`, and the optional type spelling was subsequently confirmed as the postfix `T?`;
- tuple syntax supports two or more elements, with no empty or one-element tuple;
- integer iteration methods are `up_to` and `down_to`, not the historical abbreviations;
- `count` is a property, collection pipelines are eager, `each` returns `Nothing`, and
  `reduce` requires an initial value;
- collection copy/in-place pairs use `sort`/`sort!`, `reverse`/`reverse!`,
  `unique`/`unique!`, and `shuffle`/`shuffle!`;
- logical string padding uses `pad_start` and `pad_end`; and
- regex is an ordinary roadmap library with no special literal syntax;
- ranges follow their written endpoint direction and use a positive step magnitude
  (since superseded: ranges count upward only; see the implementation decisions below).

This history is retained because it identifies exactly where confident reconstruction has
already failed. Future corrections belong here and in the affected normative section, in
the same change.

### Pre-implementation decision pass

A review immediately before the first Zig slice closed the remaining questions that would
have been answered by implementation accident. Each is recorded in its normative section;
they are collected here with the reasoning that produced them.

| Decision | Resolution | Reasoning |
| --- | --- | --- |
| Numeric widths (4.2) | `Int` is 64-bit signed, `Float` is binary64 | The overflow and conversion rules already assumed a bounded range without naming it. Arbitrary precision costs more at the C boundary and in hashing than checked overflow costs a learner. |
| Optional spelling (4.2) | Postfix `T?` | The familiar spelling from C#, Swift, and Kotlin. The clash with `?`-suffixed identifiers is lexical rather than merely visual, and is resolved by splitting a trailing `?` in type position during parsing; 4.2 records the rule and its conformance test. |
| Optional nesting (4.5) | Optionals never nest; `T??` is an error | Makes one optional relationship sufficient. The resulting ambiguity in `find`, `first`, `last`, `min`, `max`, and dictionary lookup over optional elements is accepted and paired with an unambiguous companion operation rather than fixed by nesting. |
| Overloading (7.3) | Deferred | The most expensive machinery in the design, producing the least explainable diagnostics, for ergonomics that defaults and named arguments largely already provide. Adding it later is backward compatible. |
| Type body syntax (10.6) | Braced only | The block-free form contradicted the single canonical formatter output promised in 18.3, and cost a second parsing and recovery mode. |
| Struct method capture (7.5) | Semantics kept, framing added | The behavior is ordinary value semantics; it needed a teaching equivalence rather than a different rule. |
| String normalization (9.2) | Compare normalized, store original bytes | Keeps canonical equivalence for equality while guaranteeing that file contents round-trip unchanged. |

These supersede conflicting statements elsewhere in this document. The optional spelling and
`Int` width were previously listed as open roadmap items in section 24 and have been removed
from it.

### Decisions made during implementation

Questions that surfaced while building a slice, settled with the same priorities and
recorded in their normative sections:

| Decision | Resolution | Reasoning |
| --- | --- | --- |
| Ordering (5.2) | Only numbers and strings are ordered; every type has `==` and `!=` | `true < false` has no meaning a reader would guess, so it is rejected rather than given one. |
| Uninitialized `const` (4.1) | Rejected at the declaration | A `const` can never be assigned afterward, so it would stay unassigned forever. |
| Descending literal ranges (6.4) | `5..1` is an error, not a warning | It can only be empty, so it can only be a mistake, and an error cannot be scrolled past. Computed endpoints are never reported. |
| Counting down (6.4) | `down_to`, `up_to`, `step`, and `reverse` are loopable directly; a wrong-side target counts nothing | The code states the direction, never the values. `down_to` erroring on a wrong-side target dated from self-reversing ranges; with upward-only ranges, the symmetric rule is an empty count, which keeps computed bounds safe in both directions. |
| List method results (8.5) | `remove_at`, `remove_first`, and `remove_last` return the removed element; removing from an empty list is an error; a list displays as it is written | The spec named the methods but not their results. Returning the element is the common expectation, and an error on empty matches indexing's strict bounds until optionals exist. |
| Range direction (6.4) | Ranges count upward only; a start past the end is empty | A self-reversing range turns every computed bound into an edge-case bug: `0..items.count - 1` visits `0, -1` for an empty list. `down_to` and `reverse()` already spell counting down. Supersedes the recovered endpoint-direction rule. |
| Project detection (14.1) | A directory is a project only when it contains `main.em`; otherwise a file runs alone | Including every file in the entry's directory broke the most common beginner layout, a folder of independent exercises. |
| Finding the project root (14.1, 24) | Only the file's own directory is consulted, never one above it | Searching upward would pull a folder of exercises into whatever project happens to be above it, which is the surprise 14.1 exists to avoid. A subdirectory file run on its own is then a program on its own, and the "not defined" it produces names the entry to run instead, so the rule explains itself the first time it bites. |
| What a file names (14.2, 24) | The directory is the namespace; the file names nothing | 14.2 read both ways. 14.3 had already removed filename-as-implicit-type, and 14.2 makes same-directory names directly visible, so the file cannot be part of the name without contradicting both. It also means splitting one file into two changes nothing any other file writes, which is the refactor a growing program reaches for first. |
| Namespace spelling (14.2) | One segment per directory, `snake_case` to `PascalCase`: `ui_kit/` is `UiKit` | Directories follow 3.2's file naming and namespaces read like types, so the mapping has to be stated somewhere. A directory whose name cannot be read as one is reported rather than skipped, because skipping it would make its declarations silently unreachable. |
| The unit of initialization and privacy (14.1, 14.2) | The file, not the directory | The two are separable: the directory answers "what is this called", the file answers "when does it run" and "who can see it". Keeping privacy with the file is what lets two files in one directory each have a `_helper`. |
| Reaching a file that is initializing (14.1) | A function is fine; an unfinished binding is the cycle error | Declarations are hoisted, so a function value exists before any binding does, and a body runs later. Treating every reach as a cycle rejected `const x = helper()` calling a function in its own file, which is the ordinary way to write one. |
| Module bindings outside the entry file (14.1) | Must have a value where they are declared | Only the entry file's top level runs, so there is nowhere else an assignment could happen. Reporting it at the declaration is better than letting the checker's definite assignment report it at every read. |
| A `using` collision with a local name (14.2) | The file's own namespace wins, silently | 14.2 makes same-directory names directly visible. An import that could shadow them would make adding a declaration to a neighboring file change what an unrelated file means. Only two imports conflicting with each other is ambiguity, and that is reported where the name is used. |
| Where a block's names come from (7.4, 14.1) | The file the block was written in, wherever it is called | A block passed to another file and called there is still the block that was written where it was written. The closure carries its file for the same reason it carries its scopes. |
| Integer exponentiation (5.3) | Two `Int`s give an `Int`; a negative `Int` exponent raises | Squares and cubes are the common case, and `side ** 2` printing `49.0` or failing to fit an `Int` was a papercut. Matches `//`. |
| Functions with no result (6.5, 7.2) | They return `Nothing`; no separate "no result" category | The distinction had no observable difference. Unifying them also settles that a recursive function with no result needs no annotation, since there is nothing to infer. |
| `?` predicates (3.3, 4.2) | Always return plain `Bool`; the conformance example changed | The earlier example `func valid?(): Bool?` contradicted 3.3's rule. |
| `unless` (6.2) | Removed in both forms; trailing `if` is the guard form | It only ever meant `if not`. Removing it leaves three conditional forms with distinct jobs: block `if`, trailing `if`, and the `if` expression. |
| Collection display (8.2, 8.4) | A dictionary prints `["Ava": 12]` and `[:]` when empty; a set prints `{"red"}` and `{}` | The three literals share the bracket spelling, so an empty dictionary printing `[]` would be indistinguishable from an empty list. A set printing the braces of its type says what it is at a glance, and nothing else in the language prints braces. |
| Set members as keys (8.3) | A set holds exactly what a dictionary can key by | A set is a dictionary that stores no values, and it finds a member the same way. Splitting the two rules would mean a set that can hold something it could never find again. |
| Optionals as keys (8.3) | Rejected | 8.3 requires stable equality and hashing; an absent key has nothing to hash and nothing to mean. `contains_key?` already distinguishes a missing entry from a stored `nothing`, which is the case that might otherwise want one. |
| Tuple variance (8.2, 4.4) | A tuple widens position by position; a list stays invariant | Nothing can assign to a tuple position, so a `(Int, Int)` used as a `(Float, Int)` can never be written through and observed as the wrong type. That is the entire argument that makes a list invariant, and it simply does not apply here. |
| `entry.0.1` (8.2) | The lexer reads `0.1` as a decimal number; the parser splits it where it knows a member is named | The alternative was requiring `(entry.0).1`, which is a papercut with no teaching value. Splitting it costs a few lines in the one place that already knows a position is being written. |
| A tuple's `count` (8.2, 8.5) | Tuples have none | 8.5 gives `count` to collections, whose size is a runtime question. A tuple's size is part of its type and is written in the source, so `count` could only ever return a constant the reader already typed. |
| Set literals (8.2) | Square brackets, with the set type deciding; `Set[T]` stays the type spelling | Braces in expression position meant a block, a lambda, or a set, which forced `for n in ({1, 2, 3})` and made `{}` ambiguous. Brackets already build empty dictionaries from context, so sets follow the same rule. |
| Leading-dot continuation (3.1) | A line beginning with `.` or `?.` continues the previous line | Method chaining is the pipeline notation, so chains need to wrap, and no valid line could begin with a member dot anyway. The one exception to deciding continuation from preceding tokens. |
| Widening (4.4) | `Int` widens to `Float` wherever a `Float` is expected, not only in arithmetic | The section relied on it for `[1, 2.5]` already, and `var rate: Float = 1` being an error would teach nothing. |
| String joining (9.2) | `+` joins two Strings and `+=` appends; nothing converts implicitly | Every language a beginner meets next has it, and building a string in a loop without it is awkward. It stays the only string operator, and interpolation stays the primary way to build prose. |
| `\u{...}` escape (5.1) | Writes a Unicode scalar value by code point | Combining marks and other invisible characters cannot otherwise be written in source. The braced form matches Swift, Rust, and JavaScript. |
| Strings inside collections (15.2) | Displayed quoted, with escapes | `["a, b"]` and `["a", "b"]` must not look alike. At the top level a string is still its text. |
| Searching strings (9.2) | Matches only between characters, and canonically | Section 9.1 promises characters are never split; `"café".contains?("e")` is false when `é` is one character. `replace` replaces every occurrence. |
| Unicode version (19.1) | 17.0.0, generated and checked by `tools/unicode` | Recorded so a change is deliberate; the full NormalizationTest runs whenever the tables are regenerated. |
| Loops and definite assignment (6.4) | A loop may run zero times; only a literal `while true` is known to end through `break` | Precise enough that the common `while true` search with a `break` needs no dummy initial value, while staying a rule a reader can check by eye. |
| Lambda body shape (7.4) | The body is one expression when it is written on the `=>` line and `}` follows it; otherwise the lines after `=>` are statements | `{ n => n * 2 }` and `{ n => total += n }` are both natural one-liners, and only the first produces a value. Deciding by what follows the first expression accepts both without a second spelling. |
| Function-type variance (7.1) | Functions are invariant in parameters and result | Variance is a real rule with a real explanation, but it earns its place only once there is a type hierarchy to vary over. An exact match is sound and is what a reader would guess. |
| Function equality (8.4) | Two captures of the same named function are equal; two lambdas only when they are the same closure | There is no way to compare what code does. Two evaluations of the same lambda capture different variables, so they are genuinely different functions, while `add` is the same function every time it is named. |
| Displaying a function (15.2) | `<func greet>`, or `<lambda>` for one written inline | A function has no written form, so it displays as something obviously not one rather than as a plausible value. |
| Capturing a built-in (7.5) | `print`, `write`, and `input` can only be called | They take any number of arguments of any type, which no written function type describes. The diagnostic suggests wrapping one in a lambda. |
| `each` and the unused result (5.2, 8.5) | `each` ignores what its block produces, except a one-expression body that is not a call, which is reported | That shape is section 5.2's unused result and is almost always a `map` written as an `each`. A block body that happens to return is left alone. |
| Blocks in a statement header (7.4) | The `{` after an `if`, `while`, or `for` condition opens the body, and a trailing block written there is reported against its own `{` | The rule was already stated; without a diagnostic naming it, the parameters were read as statements and produced errors that named nothing relevant. |
| Keywords after `.` (3.4, 4.5) | A member may be reached for by a keyword name, though a member is still declared with an ordinary identifier | 3.4 reserved keywords after `.` while 4.5 wrote `maybe.or(0)` twice; one had to give. Only a member name can follow a `.`, so allowing a keyword there makes nothing ambiguous, and 3.4's stated reason — that member declarations not create a second identifier grammar — is untouched. The alternative was renaming `or`, which would have broken step with `to_int_or`. |
| Narrowing a `var` (4.5) | A `var` that any lambda assigns to is never narrowed; a `const` and a parameter always are | 4.5 says a narrowed mutable binding loses the proof when "a called closure could reassign its captured binding", and which names those are is exactly what the resolver already sees. Refusing to narrow them at all is the rule a reader can check by eye, and the alternative — tracking which calls could reach such a block — would be both slower and harder to explain. |
| Narrowing after assignment (4.5) | Assigning a value that is certainly there proves it is, until something un-proves it | Otherwise `x = 5` followed by `x + 1` is an error with no way to read it as anything but a compiler failing to notice. It falls out of tracking the narrowed type in the same state a branch snapshots and restores. |
| Laziness of `or` (4.5) | The fallback is evaluated only when the value is absent | It is the one method whose name is an operator that short-circuits, and `.or(next_ticket())` should not draw a ticket it will discard. Nothing else a program can write depends on an argument running. |
| Collector roots (19.5) | Derived from the reference counts rather than from a registration API | Every holder already retains, and a count may be too high but never too low, so an unaccounted count is exactly an external holder. A missed registration would free a live object; a count that is too high only delays a free, which is the failure the collector is there to reduce rather than one it can turn into corruption. |
| Value-type mutability (4.3, 7.1, 8.1, 10.2) | `const` and parameters freeze values; the rule stops at class references | Under value semantics, mutating and replacing are indistinguishable, so a shallow `const` protected nothing coherent, and mutating a parameter's copy was a silent no-op that a beginner would write and never understand. Replaces the earlier shallow `const`, which followed C# reference-type variables. |
| A place is a path (4.3, 10.2) | Assigning to `a.b[i].c` and calling a changing method through the same shape both walk one path of indices and struct fields, and a `const` field freezes it exactly where it sits, not only at the top | 4.3 already says a `const` field can be "neither replaced nor changed", which only means something once a field can hold another struct. Checking each step as the path is walked, rather than only the root binding, is what makes `line.start.x = 1` fail when `start` is `const` even though `line` is a `var`. A tuple position is rejected the same way, since 8.2 gives no way to write through one at all. |
| Assigning through a namespace (4.3, 14.2) | Not attempted; the existing "namespace, not a value" diagnostic already covers it | `Shapes.origin.x = 1` reaches the resolver as the bare name `Shapes` once member access is walked like any other step, and `Shapes` is not a value regardless of what follows it. Inventing a struct-field-specific diagnostic here would special-case one path to a capability (assigning through a namespace) that does not exist for any other kind of target either. |
| Setting a `const` field in a constructor (4.3, 10.2) | Exactly once: only where no path into that point has set it, and never inside a loop | 10.2 lets a constructor initialize a `const` field and 4.3 says it then never changes, so a second assignment in the constructor is a change. "Never inside a loop" is the rule a reader can apply by eye; proving a loop body runs at most once is not worth what it would cost to explain. A `var` field may be set as often as the constructor likes. |
| `self` before and after construction is ready (10.2) | Each field may be read once it is certainly set; `self` as a whole, including passing it anywhere, only once every field is | 10.2 forbids `self` escaping "before all fields are ready". Tracking readiness field by field, through the same flow analysis as definite assignment, lets `self.high = self.low + size` work once `low` is set, rather than forcing every read to wait for the last field. |
| `self` inside a block in a constructor (7.4, 10.2) | Rejected for now | A block captures by reference and may run after the constructor has finished, or before every field is set, which 10.2's escape rule cannot see through. Reading what the block needs into a local first covers the need until methods give `self` a second home and the rule can be designed for both. |
| A constructor's return type (10.2) | Writing one is an error | 10.2 says constructors never return replacement values, so a written return type could only restate the struct's own name or contradict it. |
| Constructor delegation (10.2, 21) | `self(...)` is deferred with overloading | 10.2 described `self(...)` delegating to "another constructor of the same type" while allowing each type at most one constructor, so there was never another constructor to call. Delegation only means something once a type can have several, which is exactly what deferring overloading rules out; the two arrive together. |
| Which struct methods change `self` (4.3) | Worked out from the body's text: an assignment into `self`, a changing collection method reached from `self`, or a call to a method on `self` that changes it | 4.3 already rules out a `mutating` keyword. Following paths that start at `self` through field types gives the answer before any body is checked, so a call site never waits on inference, and `var copy = self` followed by a change to `copy` correctly changes nothing. |
| Calling a changing method (4.3, 8.1) | The receiver is taken out of its place for the call and put back afterwards; its binding cannot be reached another way meanwhile | Sharing the receiver with the call would make every `self.items.append(x)` copy the list, turning a loop of calls quadratic. Taking it out is exact, and the one thing it gives up — seeing the value from elsewhere mid-call — is what Swift's exclusivity rule also forbids. It is a runtime error because a block can reach a binding in ways the checker does not track. |
| Where named arguments apply (7.3) | Calls to a function, method, or type written by its own name | A name belongs to a declaration's parameter. A lambda or a function held in a variable has only a function type, which has no names, and the prelude and built-in methods declare none, so a name there would have nothing to match. |
| The generated constructor's parameters (7.3, 10.2) | Every field, in declaration order, with a defaulted field optional; no ordering rule for fields | 7.3's "defaults follow required parameters" exists so a positional call can reach every required parameter. Imposing it on fields would dictate how a struct is laid out and displayed; named arguments already reach a required field after a defaulted one. |
| A `const` field with a default (4.3, 10.2) | Its default always runs before a custom constructor, so the constructor cannot set it | It is set exactly once, by the default. A constructor that should decide the value is written without the default. |
| Member names (10, 10.3) | A field, a property, and a method of one type share one name space, and a type cannot declare two methods of one name | `value.name` has to mean one thing, and overloading is deferred. |
| A getter and `self` (10.3) | A getter may not change `self` | 10.3 leaves side effects to convention, but this one decides what a read may be called on: a getter that changed `self` would make reading a property of a `const` an error. The checker already infers which bodies change `self`, so the rule costs nothing to state or check. |
| Accessors are methods (10.3) | A property's getter and setter are checked and run as methods of the type, keyed `Type::name` and `Type::name=` | Nothing about calling, inference, captures, or changing `self` differs from a method, so nothing is written twice; only reaching them differs, which is a member read or an assignment instead of a call. |
| Where a type-level member is declared (10.4) | Inside its own type's braces, naming that type | 10.4 shows `func Vector2.origin()` without saying where it goes. Inside the type keeps a type's members in one place for a reader and one declaration for the checker; accepting it elsewhere would be extension of a type from outside, a separate feature with its own questions about files, namespaces, and privacy. |
| Type-level and instance member names (10.3, 10.4) | One name space for both | `Player.count` and `player.count` meaning different things would be legal but misleading, and the diagnostic for reaching a member the wrong way can only name the right way if the name identifies one member. |
| Inferring a type-level field's type (4.1, 7.2, 10.4) | Optional annotation; inferred from the value on first need, and a cycle through a function whose return type is also inferred needs one of the two annotated | This matches module-level bindings, which the fields otherwise behave like. The cycle rule is 7.2's rule for recursive functions, reached through a field instead of a call. |
| Class display (10.1, 15.2) | Field by field like a struct, with `Name(...)` for an object already being displayed | Showing the fields is what a beginner needs while learning; an address or bare type name hides exactly what changed. Objects form cycles, which a struct cannot, and the marker ends one without losing the rest of the value. |
| Changes through a trait's value (4.3, 11.2) | Treated as a value: a change needs a `var`, and a requirement changes when any struct supplying it does | Whether a trait's value is shared is not known statically. Treating it as a value is the rule that is always safe, and it loses nothing for a class, which is changed in place either way. |
| `@override` for traits (11.2) | Required on a method supplying or replacing a trait's, in structs too; never on a property | 11.2 settles it for methods and properties. A struct adopting a trait is the one case where a struct's method replaces something, so the annotation means the same thing there. |
| Enum values inside the enum (10.4, 12) | Written `Direction.north` everywhere, including the enum's own methods | Enum values are type-level members, which are always reached through the type. A bare `north` inside the braces would be a second spelling that stops working one line outside them. |
| Enum value lists (12) | Values come before every member, separated by newlines or commas | The spec's example lists one per line; commas let a short enum such as `small, medium, large` stay on one line, as `when` alternatives do. Requiring values first keeps the whole set readable in one place. |
| When a `case` is complete (4.1, 6.3) | `else`, or coverage of every value of an enum or `Bool` subject, plus `nothing` when it may be absent; a complete statement `case` counts as running one arm | 6.3 lets a value case over an enum omit `else` when all values are covered. Treating the statement form the same way lets a function return from every arm without an unreachable `return` after the `case`, and needs no rule a reader cannot see: the arms list every value. |
| `case` value types (6.3) | Arms agree on a type; `Int` with `Float` gives `Float`, and a `nothing` arm makes the result optional | A list literal mixing `nothing` needs an annotation because `List[T]?` and `List[T?]` differ; one value has only `T?` to mean, so requiring an annotation would add nothing. |
| Braces inside parentheses (3.1) | A `{` restores newline termination until its `}` | 3.1 suppresses newlines inside parentheses so arguments can wrap, but a `case` or a block passed as an argument has lines of its own, which could not be separated at all before. |
| What `Self` is on a class (11.4) | The first class along the base chain to adopt the trait | A subclass inherits its base class's methods with their types unchanged, so taking `Self` as the subclass would make every inherited implementation stop conforming. Swift needs `final` or `Self`-returning initializers to square this; fixing `Self` where the trait is adopted keeps it sound with nothing new to learn. |
| `Self` through a value seen as a trait (11.4) | A `Self` result is the trait; a member taking `Self` cannot be called | The value could be of any adopting type, so nothing can be checked to match its `Self`. Inside the trait's own defaults `self` is an opaque `Self`, which is what makes defaults that combine values of the same type possible without generics. |
| Annotated arithmetic operators (11.5) | `@operator("+")`/`-`/`*`/`/` registers public struct/class methods; selection uses the left static type, ordinary parameter compatibility, and pairwise-disjoint operand domains, then invokes the selected key through ordinary virtual dispatch | Mixed results such as `Matrix * Vector -> Vector` cannot be expressed by conversion-based designs, while general overloading would rewrite member lookup, constructors, diagnostics, and tooling. The annotation keeps arithmetic selection narrow, preserves `Int`-to-`Float` widening, and leaves ordinary method names unique. The former arithmetic authorization traits are retired; `Ordered` remains a trait contract. |
| Operators and change (4.3, 11.5) | A struct method that changes `self` cannot back an operator | `a + b` reads as a value, and every other operator leaves its operands alone; a change to the left operand's copy would be silently lost. |
| Where trait conflicts are reported (11.2) | At the declaration that first brings the conflicting traits together | Reporting at every subclass and every trait built on top would repeat one mistake many times, far from where it can be fixed. |
| Where `is` binds (4.4) | With the comparisons, without chaining; `is not` is rejected with a correction | Like Kotlin and Swift, a test reads as one condition that `not`, `and`, and `or` combine. A second spelling for the negated test would be the kind of duplicate 5.2 declines for `!`. |
| Narrowing inside `and` and `or` (4.4, 4.5) | The right side is checked knowing how the left side went | It runs only then, so the proof holds, and without it `animal is Dog and animal.tricks > 0` and `x != nothing and x > 3` needed a nested `if`. |
| The always-known type test warning (4.4) | A warning for an exactly known true result, unrelated classes known false, or a class whose declared subclasses never adopt the tested trait | The test remains a valid `Bool` and still evaluates its operand once. A trait-typed value, struct, or enum stays out of the false proof until its possible values are designed. |
| Reusing a base class's names (10.7) | Not allowed for any member, private ones included, except a public method or property replaced with `@override` | 10.4 already keeps one name space so a name means one thing. Allowing a private name to be reused would give one object two fields of one name, each seen from different braces, which is harder to explain than a rename. |
| Override results (10.7) | The same type, a subclass where the replaced method gives a class, or a value always present where it gives an optional of that type; parameters must match exactly | A subclass object needs nothing done to it to stand in for its base class, and neither does a present value for its optional, so a covariant result costs nothing and lets `clone()` or a factory give its own class, or a subclass promise the value a base class may not have (as Swift and Kotlin allow). Found in the inheritance review. Parameter variance is the confusing direction and is not needed yet. Numeric widening is excluded because it would need a conversion the calling code does not know to make. |
| Reaching an override too early (10.2, 10.7) | A runtime error when an object runs a version of a method or property declared by a class whose part of it has not begun | The base-first order and the permission to pass `self` on once a base class's fields are set leave a way for a subclass's override to read an unset field, which a static rule could close only by forbidding that permission too. Checking at dispatch costs one comparison where an override runs. A method taken from the object is checked when called rather than when taken, since taking it runs nothing (found in the inheritance review). |
| A subclass without a constructor (10.2, 10.7) | Built with no arguments; its own fields all need defaults and its base class must build without arguments | 10.2 states this. A generated constructor taking a subclass's fields as well as its base class's would have to invent an order and names across two declarations. |
| Exclusive access and objects (4.3, 10.1) | Not applied to an object as a whole; a struct in an object's field is taken out of the field while a setter or changing method runs on it, and reaching that field meanwhile is a runtime error | The class slice first stored a copy back instead, which silently discarded any change made to the field during the call and let the call's own code read the old value. That is the half-changed state 4.3 exists to prevent, and Swift likewise enforces exclusive access to a class's stored properties at runtime while leaving the reference itself unchecked. Found in the object model review. |
| What `const` and the change inference see through (4.3, 10.1) | Both stop at the first object on a path | "The rule stops at the first reference, which is exactly where sharing begins." The same boundary decides whether a struct method changes its struct, so `self.log.lines.append(x)` on a struct holding a `Log` object leaves the struct unchanged and works on a `const`. |
| What a nested function sees (7.1) | The variables above its declaration, as a lambda there would; uses are checked | 7.1 says both "capture surrounding bindings like lambdas" and "hoisted". Seeing only what is above matches a lambda and matches what a top-level function sees of the module, so one rule covers every function. Hoisting then only moves where it can be called from, and each call above the declaration is checked against what the function reads. |
| When a module lambda's captures are checked (7.4) | At a direct call through its module binding, not when the lambda is created | Creating a lambda does not evaluate its body, so declaration-site checking rejected a safe `const read = { => later }` before `later` was assigned. A known module binding retains enough information to check its real call site, preserving the early-call error without requiring general flow analysis through arbitrary function values. |
| Using a nested function in a lambda or as a value (7.1) | Judged where it is written | The function could run from there, and 7.1 says hoisting never permits reading an uninitialized captured variable. Judging where the lambda or value is finally called would need flow analysis through values. The cost is rejecting some programs that would run, and moving the use below the assignment always fixes that. |
| Nested tuple patterns (7.4, 8.2) | Allowed wherever a tuple is unpacked | 7.4 requires them in lambda parameters. One pattern form everywhere is simpler to teach than a rule that nests in a block's header but not in `const (a, (b, c)) = ...`. |
| Calling a captured changing method from inside itself (4.3, 7.5) | Runtime error | The call has the copy to itself while it changes it, as a changing method has its receiver. Letting the inner call work on the same copy would make the outer call's result silently overwrite the inner one's changes. |
| Equality of captured methods and nested functions (7.1, 7.5) | Equal only when they are the same captured value | Each carries state, like a lambda that captured variables, so equal-looking captures can behave differently after either is called: two calls of a function that returns its nested `next` give two different counters. A top-level function carries none, which is why capturing it twice gives equal values. |
| Where a private member can be reached (10.5) | Only from code inside its own type's braces, including other values of that type | `protected` is deferred, so a subclass would not see a private member either; the braces are the boundary a reader can see. Module-level privacy stops at the file because the file is a module's unit (14.2), but a type's unit is its declaration. Allowing `other._count` for another value of the same type keeps equality helpers and merges writable without a public accessor. |
| Private fields and the generated constructor (7.3, 10.2, 10.5) | Still one parameter per field in declaration order; outside the type a call may not give a private field a value | Dropping private fields from the parameters would give a field a different position depending on who calls. Keeping them lets the type's own functions pass everything, while outside callers leave a private field to its default and name the fields after it. |
| Narrowing a type-level field (4.5, 10.4) | Not narrowed, even after assigning a present value | The field is one binding the whole program shares, so any call between the proof and the use can set it back to `nothing`. `.or(...)`, or copying it into a local first, is the way to use one. |
| When a changing method reaches its receiver (4.3, 5.2, 7.3) | The receiver is a place: its indices are evaluated first, and the place itself is reached once the arguments are, so an argument that replaces the variable is seen by the call. A method that only reads receives the receiver's value, read before its arguments | This is how assignment into a place and the changing collection methods already behave, and reaching the place first would make `items.append(items.count)`, and any argument that reads the receiver, an error under 4.3's exclusivity rule. A reading method has no place, only an operand, which 5.2 reads left to right. |
| Defaults of a changing method (4.3, 7.3) | Evaluated before the call takes its receiver, seeing `self` as it is before the call; a default may not change `self` | 7.3 counts omitted defaults among a call's arguments, so exclusivity has not begun while they run, and `t.mark()` with a default that reads `t` is not an error. A default that changed `self` would be lost on a method that only reads, and would reach a `const`; like a getter (10.3), it only works out a value. |
| A changing method or setter that raises (4.3, 13.2) | Returns its receiver to its place with mutations completed before the error still visible | Errors do not provide transaction semantics for class objects, collections, or other ordinary state. Restoring the changed struct keeps value methods consistent with that rule and avoids replacing a reachable value with `nothing` during unwinding. Prepare a separate value before assignment when a change must be all-or-nothing. |
| Narrowing a module variable a function assigns (4.5, 7.1) | Never narrowed; a `const` copy is | 4.5 already refused narrowing where a called closure could reassign the binding, and a named function reaches module variables the same way. Tracking which calls could run the assigning function would be interprocedural analysis with the same over-reporting as the capture check, for a pattern a `const` copy states more clearly. Without this, `check` accepted a program that crashed. |
| Where a trailing block goes (7.3, 7.4) | Always the final parameter, and exempt from "no positional arguments after named ones" | 7.4 already calls it the final argument position. Treating it as one more positional argument rejected `repeat(times: 2) { ... }`, and put the block into the next unfilled parameter when defaults were skipped. |
| A function parameter after defaulted ones (7.3, 7.4) | Allowed when it is the final parameter and has a function type; any other required parameter after a defaulted one is still an error | 7.3's rule exists so a positional call can reach every required parameter. A trailing block reaches the final one, so `func grid(width: Int, height: Int = 2, cell: func(Int, Int))` loses nothing, and without the exception a function taking a block could have no defaults before it at all. |
| `self` in a constructor's parameter defaults (7.3, 10.2) | Allowed, under construction's readiness rules: a default may read fields that have defaults of their own, since those run first | A method's defaults already read `self`, and the runtime binds `self` before evaluating defaults. The parser had rejected it with a message claiming `self` was only available inside a constructor. |
| Narrowing into a block (4.4, 4.5, 7.4) | A captured `var` that any assignment gives a new value is seen at its declared type inside a block, whatever was proved outside it | A block created inside `if pet is Dog` and called after `pet = Animal()` read a field the object did not have and crashed; the same held for a proof of presence. Kotlin refuses the same smart cast for a captured variable that is changed. Keyed by name like the other narrowing facts, so it errs toward not narrowing; a `const` copy states the proof. Found in the type test review. |
| `Trait.method` as a value (11.2) | Rejected; it can only be called | Accepted by the checker, it crashed when called. Supporting it means choosing whether the value's own version or the trait's runs, and whether a changing default copies its receiver; `value.method` already covers the common need. Found in the trait review. |
| Narrowing across a loop (4.5, 6.4) | A name a loop body assigns loses its narrowing before the condition and body are checked; the body may prove it again | A loop body is checked once from the state before the loop, which is exact for definite assignment because assignment only accumulates. A proof of presence can be lost, so a body that sets a name back to `nothing` would otherwise leave the next iteration, the condition, and the code after the loop trusting a proof that no longer holds. |
| Naming a lost class narrowing (4.4, 4.5) | The member-not-found help names the `is` test that once held and says an assignment since then is why it no longer does, rather than suggesting the reader write the very test they are already inside | `if a is Dog { a = Animal(); print(a.tricks) }` told the reader to wrap the read in `if a is Dog { ... }`, which reads as nonsense already being inside one. Tracked only for a plain-name class test, since that is the shape a member lookup like this comes from. Found in the diagnostics review. |
| Constructing a message-only error subclass (13.1) | It gets `Error(message)` when it declares no constructor and its complete stored state is only the inherited message; a hierarchy with more fields uses ordinary subclass constructors | Section 13's canonical `class InvalidScore extends Error { }` is immediately raised as `InvalidScore("...")`. Requiring boilerplate that only forwards the message would contradict that teaching example and make the most common custom error need ceremony, while bypassing fields or constructor arguments from an intermediate error class would create an invalid object. |
| An assertion's optional message (16.2) | Written after a comma: `assert condition, "explanation"` | The comma reads as one assertion with supporting context, requires no new keyword or parentheses, and leaves the condition as the first thing a beginner sees. The message is evaluated only when the assertion fails. |
| Brace style, revisited (3.4, 18.3) | Both Stroustrup and Allman are legal source; a project picks one canonical style in `emerald.toml`'s `brace_style`, and the formatter always normalizes to it | The original rule made Stroustrup the only legal spelling anywhere, reasoning from the formatter's "one canonical output" promise as if that meant one output for the whole language rather than one per project. But brace placement is whitespace, which 3.1 already calls non-semantic, and casing (3.3) already shows the language tolerating a non-conventional choice as a style matter rather than banning it outright. The two styles aren't symmetric with casing, though: the formatter can rewrite whitespace unconditionally, but it can't safely rename an identifier, which is why casing stays a warning rather than a rewrite. 18.3's promise survives intact — every file in a project still normalizes to exactly one style — it is just no longer the same style for every project. |
| A missing or unreadable file's exit status (18.1) | `66` (`sysexits.h`'s `EX_NOINPUT`), not `64` | `check`/`run`/`test`/`format` all shared `64` with a malformed invocation before this, but the two are different problems for a caller to act on: `64` means the command itself was typed wrong (bad flags, wrong argument count), while a well-formed command naming a path that turns out missing or unreadable is an environment problem, exactly what `EX_NOINPUT` exists to distinguish. `70` (`EX_SOFTWARE`, `internal_failure`) already established that this project borrows meanings from `sysexits.h` rather than inventing its own, so `66` continues that rather than picking an arbitrary unused number. |
| Custom equality and hashing, undeferred (8.3, 8.4, 11.5) | `Equatable.equals(other: Self): Bool` and `Hashable.hash(): Int` (which requires `Equatable`), the same shape as `Ordered`; `Hashable` alone lifts a struct's dictionary/set-key eligibility past the structural default, and adopting `Equatable` without `Hashable` is refused as a key rather than silently kept on the old structural hash | The gap was explicit ("custom equality, hashing... are deferred") once `Textual` gave the value-protocol family a visible hole: a type could control display, ordering, and arithmetic, but not `==` or its own key behavior. `Value.equals`/`Value.hash` had no way to call a user method at all — both were plain functions with no interpreter context — so this reused `Textual`'s own answer to that exact problem: `Value.writeThrough`'s `textual: anytype` context, generalized into `equatable`/`hashable` parameters threaded through every recursive comparison and hash (list elements, dictionary values, struct fields, and `Heap.zig`'s own key lookup, which calls `Value.equals` to resolve collisions). Classes stay excluded from key eligibility regardless of `Hashable`: the exclusion was never about missing equality, only that a class's fields can change while it is stored as a key, which `Hashable` does not address. A future pass could lift that specific case for a class made entirely of `const` fields, which cannot change after construction — floated, not designed, in the roadmap (24). |
| A mixed sibling-class literal infers its base, undeferred (4.4, 10.7) | A list, dictionary, or value-producing `case` whose elements are different but related classes infers their nearest shared base (`Type.User.commonBase`, a plain walk up 10.7's single-inheritance chain), rather than reporting a mismatch that an explicit `List[Animal]` annotation was already accepted under | `[Dog(), Cat()]` failing to type-check when `const pets: List[Animal] = [Dog(), Cat()]` already worked was exactly the surprise 4.4's own widening principle argues against: `[1, 2.5]` already infers `List[Float]` rather than demanding an annotation, and a heterogeneous collection under a shared base is one of the most ordinary patterns an OOP-capable language has. Scoped to a shared class only, not a shared trait: inferring across a trait would expose only the trait's own contract on the result (11.2), a real loss of what the elements' own type already offered, unlike widening to a base class the elements already were. Guarded against either side being optional, since `Type.structOf` has no way to carry a `?` its caller did not already have on hand — left to the ordinary mismatch report rather than risk silently dropping one. |
| `File.with_open` implementation (13.3, 15.3) | Native dispatch invokes the block and defers `close` | `File` type-level functions already dispatch natively as a namespace, so a prelude implementation would require a special exception to that routing. Keeping cleanup beside the native handle state makes closure on both normal and error unwinding direct and testable. |
| `Bytes` storage (15.3) | Reuse `Heap.Text`'s immutable ref-counted byte buffer under a distinct `Value.Kind.bytes` tag | Text and raw bytes have the same ownership, collector, and copying needs; duplicating that machinery would add a second lifetime path with no benefit. The tag keeps their contracts separate: only String is Unicode-aware and only Bytes permits invalid UTF-8. |
| Empty bodies (18.3) | `{ }` on the header's line, in both brace styles; a comment-only body keeps its lines | The formatter used to open every body onto separate lines, so the spec's own `class InvalidScore extends Error { }` and `else { }` were not canonical. An empty body is where one line reads best, and it is what the spec already wrote; keeping any author-chosen one-line body would give ordinary code two canonical shapes. Allman's own-line brace opens a body's lines, and an empty body has none, so the rule does not vary by brace style. The spacing is the spec's `{ }`. |
| Nested types (14.3) | Declared bare, keyed `Outer::Inner` as a type-level member, always reached qualified, displayed without the namespace; traits may not contain one; 10.5's braces rule decides privacy both ways | 14.3 described nested types as settled, but nothing implemented them and nothing recorded the gap until the Console styling plan needed `Console.Color`. The `::` key is 10.4's type-member form, which cannot collide with a directory namespace's `Outer.Inner`. A receiver in the declaration (`enum Console.Color`) would distinguish nothing, since a type is never an instance member. Always qualifying follows 10.4 and enum values; the one-line bare declaration of a member of a nested type (`func Pair.zero()`) matches how the nested type itself is declared. Display keeps the nesting because it is part of the type's name, and drops the namespace as namespaced types already do. The platform libraries (`Graphics`, `Gui`, `Game`) will want the same shape. |
| A declaration sharing a namespace's name (14.2, 14.3) | An error at the declaration, naming the directory | The declaration used to win silently, so every member of the namespace became unreachable through that path and the only symptom was "has no type-level member" at a use. Nested types (14.3) would have made the same path legitimately mean either one, so the collision is refused rather than resolved by a precedence rule a reader cannot see. Only an exact key match can collide, since member keys hold `::` and private keys hold `#`. Built-in names are not covered: `Math` and `Program` already yield to a project namespace of the same name, while prelude classes such as `File` do not, and aligning those is a separate decision. |

## 23. Consistency rules for future work

Before adding or changing a feature:

1. Check this document, including section 22's table of confirmed departures from the
   historical prototype (no prototype artifacts remain in this repository to consult
   directly).
2. Write a canonical source example and its expected type or behavior.
3. Record interactions with optionals, mutation, equality, errors, and source diagnostics.
4. Prefer ordinary library code over syntax when both are equally clear.
5. Do not introduce a generic abstraction solely to implement several built-ins.
6. Add the decision and rationale in the same change as its implementation.
7. Add an end-to-end behavioral test for semantics that a future backend could inherit
   incorrectly from its host.

The language grammar must eventually be generated or checked against these examples. The
standard-library reference must be generated from authoritative signatures rather than
maintained as a second handwritten list.

## 24. Evidence-driven roadmap

The complete conversation audit and the final uncertainty pass leave no known semantic
question blocking the first interpreter slices. The following decisions intentionally wait
for working Emerald programs, implementation measurements, or a dedicated design pass:

- nondecimal numeric literals and numeric suffixes;
- whether `struct` should become `value`, so the declaration spells out Emerald's
  value-versus-reference distinction. Revisit this only as a dedicated syntax design pass,
  with beginner-facing examples and a migration assessment;
- overloading, including overloaded constructors and `self(...)` delegation between them,
  if real Emerald programs show that defaults, named arguments, and named factory functions
  are genuinely insufficient;
- braceless type bodies (10.6), in which a file declaring one type omits that type's braces
  and its body runs to end of file. The earlier draft was removed rather than rejected on
  principle, and a proposal must answer 10.6's objections directly: one canonical formatter
  output (18.3) with no second, unrelated construct to normalize; one parsing mode that
  error recovery understands; and a single way to teach a class declaration. It must also
  say how the form interacts with multiple types per file (14.3), nested types, and 3.4's
  brace styles;
- immutable collection views, covariance, `Any`, user generics, and user `Iterable`;
- whether a class made entirely of `const` fields (which cannot change after construction,
  unlike an ordinary class) could be a dictionary or set key when it adopts `Hashable`
  (8.3, 8.4). Classes are excluded today for a mutability reason `Hashable` does not
  address on its own; this would need its own eligibility rule, checked statically rather
  than trusted the way Java, Swift, and C# trust a mutable key not to change while stored;
- stable C ABI declarations and ownership rules based on an actual library binding;
- what else `emerald.toml` holds and how it interacts with `main.em`. The rest of the
  project rules were settled with the project slice and are recorded in 14.1, 14.2, and the
  decision table in 22. `brace_style` (3.4) is the one settled key so far. Floated for a
  future pass, not yet designed: more formatting-convention keys beyond brace style, and a
  configurable warning level for formatting-adjacent diagnostics (such as 17.2's
  indentation-suggests-a-different-scope warning). Both would cut against 18.3's "one
  canonical output" formatter contract and 3.3's precedent of a style choice being a fixed
  warning rather than a configurable severity, so the design question is not merely which
  keys to add but whether `emerald.toml` is meant to grow into a lint-style
  per-rule-severity config (à la ESLint/Rubocop) or stay closer to a formatter with a
  small, closed set of style axes (à la rustfmt/gofmt) — those are different tools with
  different guarantees, and the answer changes what "sensible defaults, but developer
  control" is allowed to mean here;
- project templates and the eventual build, distribution, and package commands;
- generated documentation and its searchable reference interface;
- serialization, filesystem encoding policy, clocks, dates, time zones, and networking;
- the runtime error taxonomy, expanded alongside the operations that need it. Existing
  named requirements include `RecursionError` for the recursion boundary and `InputError`
  for input failures; conversion, filesystem, regex, networking, and similar errors receive
  specific types when their producing APIs are implemented or revisited;
- an official platform-library family, shipped with Emerald rather than acquired through
  packages, so beginners can make visible and interactive programs from one installation.
  `Console` comes first: styled immediate terminal output and line-oriented interaction.
  `Tui`, `Graphics`, `Gui`, `Audio`, and `Game` are later, separate libraries rather than one
  forced abstraction. Each begins with a small design proposal and real beginner programs;
  this roadmap does not precommit widget APIs, TUI/GUI compatibility, or a shared event model;
- concurrency and async as a dedicated design project after the single-threaded runtime.

Macros remain deferred as a separate language-design problem. If real boilerplate later
justifies them, hygiene, expansion visibility, diagnostics, and whether derivation is their
first use must be designed together. No synthetic-source or expansion contract is reserved
now.

These questions are roadmap inputs rather than gaps to fill speculatively. Each receives a
small proposal and representative program when its implementation slice becomes current.

## 25. Definition of ready for implementation

The project is ready for its first Zig slice when:

- this document and README agree that this is the only current rewrite context;
- first-program syntax has no provisional tokens;
- source spans and diagnostic output have one canonical example;
- integer literal and basic arithmetic semantics are pinned by examples;
- `var`, `const`, assignment, `print`, and block syntax are exact enough for a parser;
- a minimal directory layout and build command are documented;
- the first end-to-end expected-output test is written before or with the implementation.

Later slices have their own readiness gate: choose any relevant roadmap item from section
24, write its examples, then implement it. This prevents an unrelated future feature—such
as async or generic traits—from blocking an arithmetic interpreter while also preventing
implementation accident from deciding the feature prematurely.
