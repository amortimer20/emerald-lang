# Rule coverage: rules without cases

Date: 2026-10-28. This is the "rules without cases" measurement of the whole-codebase review
(`docs/codebase-review-plan.md`, section 3), and it is area 3's worklist.

Method: each section of `docs/rewrite-context.md` was read and every testable rule it states
(a stated behavior or result, an error or warning, a constraint, an edge case with a stated
result) was listed. Each rule was then searched for with grep, by construct, method name, and
message text, across `conformance/` (`run/`, `diagnostics/`, `runtime-errors/`, `format/`,
`lsp/`, `repl/`, and the smaller `lexical/`, `color/`, `http/`, `local-zone/` directories) and
the `test "..."` blocks in `src/*.zig`, opening the case when unsure. A rule counts as covered
only when a case exercises that rule's specific behavior or edge, not merely the feature.
History, rationale, deferred features (21), the decisions table (22), and roadmap prose (24)
are skipped, as are sections with no testable rule of their own (1, 15.7, 18.1.1, 18.2, 18.6,
19.1, 20, 23, 25). Sections 3 to 15 were done rule by rule; sections 16 to 19 more coarsely,
one row per rule but with less opening of cases, so a "none" there is a little more likely to have a
case the search missed. No case was run for this measurement: "covered" means a case exists,
not that it passes.

Conventions: `src/emerald.zig: "..."` names a unit test by its title; a conformance path is the
`.em` file (the `.input` file for REPL cases, the directory for a project case). `build.zig: name`
names one of the end-to-end CLI checks in `build.zig`'s `test` step, which run the real binary
and assert its output and exit status; they were found during the search and are counted as
tests. When a rule has several stated parts and only some are covered, the row names what
covers each part and marks the uncovered part **none**; any row containing **none** counts as
uncovered in the summary.

## 2. A first program

| Rule | Covered by |
| --- | --- |
| The first program runs with no wrapper, `input` and `print` callable bare | `conformance/run/first-program.em` |
| `write` prints without a newline, `print` with one | `conformance/run/print-arguments.em`, `src/emerald.zig: "print takes zero or more values separated by one space"` |

## 3.1 Files and encoding

| Rule | Covered by |
| --- | --- |
| Windows line endings are accepted like Unix ones | `src/Lexer.zig: "a windows line ending behaves exactly like a unix one"`, `src/Source.zig: "carriage returns are excluded from line text"` |
| An optional UTF-8 byte-order mark is accepted | `src/Source.zig: "a byte-order mark is removed and does not shift offsets"` |
| "Malformed input is reported at the offending byte span" | `conformance/diagnostics/invalid-utf8.em`, `src/Source.zig: "invalid UTF-8 is reported at the offending byte span"` |
| The formatter writes UTF-8 "without a byte-order mark" | **none** |
| The formatter "uses one consistent line-ending style" (CRLF input formats to one style) | **none** |
| Newlines are ignored while parentheses or brackets are open | `conformance/lexical/line-continuation.em`, `src/Lexer.zig: "newlines are suppressed while parentheses or brackets are open"` |
| A newline after a binary operator, comma, or member dot continues the statement | `src/Lexer.zig: "a newline after a binary operator continues the statement"`, `src/Lexer.zig: "a newline after a comma or member dot continues the statement"` |
| A block or `case` written inside parentheses restores newline termination until its braces close | `src/Lexer.zig: "a brace inside parentheses ends its lines again until it closes"` |
| A line whose first token is `.` or `?.` continues the line before; blank lines and comments between are skipped | `conformance/lexical/leading-dot.em`, `src/Lexer.zig: "a line that begins with a member dot continues the line before it"` |
| A line beginning with `..` does not continue the previous line | **none** |
| "There is no backslash continuation syntax" (a trailing `\` is an error) | **none** |
| Semicolons are rejected | `conformance/diagnostics/semicolon.em`, `src/Lexer.zig: "a semicolon is rejected with an explanation rather than accepted quietly"` |

## 3.2 Comments

| Rule | Covered by |
| --- | --- |
| `#`, `##`, and `#[ ... ]#` forms; `###` is documentation text, not a third form | `conformance/lexical/comments.em`, `src/Lexer.zig: "a third hash is documentation text, not a third comment form"` |
| "Block comments nest" | `src/Lexer.zig: "block comments nest"` |
| "An unclosed block comment reports its opening `#[`" | `conformance/diagnostics/unclosed-block-comment.em`, `src/Lexer.zig: "an unclosed block comment is reported at its opening"` |
| An orphaned `##` block produces a warning | `conformance/diagnostics/orphaned-doc-comment.em` |
| Documentation warnings apply to program files, not the prelude | **none** |
| An override without its own documentation inherits the overridden text, labelled with its source | **none** |
| Several requirements with different text are each presented, not one chosen | **none** |
| Private helper documentation does not become part of an adopter's public API | **none** |

## 3.3 Naming

| Rule | Covered by |
| --- | --- |
| Casing violations are style warnings, not errors | `conformance/diagnostics/declaration-casing.em`, `conformance/diagnostics/constant-casing-nouns.em` |
| A name ending in `?` must give a `Bool`; anything else is a type error | `conformance/diagnostics/question-name-result.em`, `conformance/diagnostics/predicate-questions.em` |
| A `Bool` result does not require the `?` | `conformance/run/bool-action-name.em` |
| An `@override` receives no casing warning | `conformance/diagnostics/declaration-casing.em` (`Child.DoThing`) |
| The `?` result rule applies to overrides and the prelude too | **none** (no case overrides a `?` method with a non-`Bool` result) |
| A leading underscore marks a private member; there is no `private` keyword | `conformance/diagnostics/private-members.em` (leading underscore); the keyword's absence: **none** |
| Identifiers follow Unicode identifier rules and exclude emoji | `conformance/diagnostics/emoji-name.em`, `conformance/diagnostics/unicode-identifier-rejected.em`, `src/unicode.zig: "identifier characters follow XID, which already excludes emoji"` |
| Canonically equivalent spellings denote the same name; names are case-sensitive | `conformance/run/unicode-names.em`, `src/emerald.zig: "names follow Unicode identifier rules and normalize"` |

## 3.4 Braces and parentheses

| Rule | Covered by |
| --- | --- |
| Both Stroustrup and Allman brace placement parse | `src/Parser.zig: "Allman brace style parses for ..."` (six tests) |
| `else`, `catch`, and `finally` begin their own lines | `src/conformance.zig: "else, catch, and finally start their own lines"`, `conformance/run/conditionals.em` |
| `brace_style` in `emerald.toml` selects the canonical style, defaulting to `stroustrup` | `src/Project.zig: "a project reads its brace style from emerald.toml, defaulting to stroustrup"` |
| The formatter normalizes every file to the project's one style, whichever it was written in | `src/Formatter.zig: "the formatter normalizes to Allman when a project asks for it"`, `src/Formatter.zig: "the formatter accepts Allman-written source and still normalizes to Stroustrup"` |
| "A formatter must not remove grouping that changes meaning" | `conformance/format/operator-precedence.em`, `src/Formatter.zig: "redundant grouping parentheses are dropped, load-bearing ones are kept"` |
| A bare method name obtains the bound callable; parentheses call | `conformance/run/method-values.em` |
| A bare anonymous block is not a standalone statement | **none** |
| Keywords are reserved as declared names | ``src/emerald.zig: "section 3.4: a keyword may name a member, which is what `.or` needs"`` (`func or` is rejected) |
| The name after `.` may be a keyword (`maybe.or(0)`) | ``src/emerald.zig: "section 3.4: a keyword may name a member, which is what `.or` needs"`` |
| At least 256 nested delimiters are accepted; the 257th is a normal diagnostic at the delimiter | `src/emerald.zig: "section 3.4: 256 levels of nesting are accepted and the 257th is reported"` |

## 4.1 Static typing and inference

| Rule | Covered by |
| --- | --- |
| A local's type is inferred from its initializer | `conformance/run/typed-declarations.em`, `src/emerald.zig: "a local is inferred from its initializer"` |
| An uninitialized variable is allowed only with an explicit type | `src/emerald.zig: "an uninitialized variable needs an explicit type"` |
| Reading before definite assignment is an error, proved through control flow | `conformance/diagnostics/definite-assignment.em`, `src/emerald.zig: "assignment on every branch proves definite assignment"` |
| A `const` without an initializer is rejected where it is written | `conformance/diagnostics/const-without-value.em`, `src/emerald.zig: "a const needs its value where it is declared"` |

## 4.2 Initial built-in types

| Rule | Covered by |
| --- | --- |
| `Int` is 64-bit signed, `-9223372036854775808` through `9223372036854775807` | `conformance/run/int-range.em`, `src/emerald.zig: "a number outside the Int range is rejected at its literal"` |
| `Float` is IEEE-754 binary64 | `conformance/run/float-display.em` |
| `Nothing`'s one value is `nothing` | `src/emerald.zig: "nothing is a value and print has no result"` |
| `List[String]?` and `List[String?]` are different types | `src/Lexer.zig: "an optional collection type puts the question mark on its own"`, ``src/emerald.zig: "section 4.2: the parser splits a trailing `?` in type position"`` |
| In type position the parser splits a trailing `?` off an identifier | ``src/emerald.zig: "section 4.2: the parser splits a trailing `?` in type position"`` |
| Required case: `func valid?(input: Int?): Bool` keeps `valid?` and splits `Int?` | `conformance/run/optionals.em`, `src/Lexer.zig: "the optional type conformance case from section 4.2"`, ``src/emerald.zig: "section 4.2: the conformance declaration using both meanings of `?`"`` |

## 4.3 `var` and `const`

| Rule | Covered by |
| --- | --- |
| `var` permits rebinding; `const` does not | `conformance/run/bindings.em`, `conformance/diagnostics/const-reassignment.em` |
| A `const` list, dictionary, set, tuple, or struct can be neither replaced nor mutated | `conformance/diagnostics/const-list-mutation.em`, `conformance/diagnostics/const-dictionary-mutation.em`, `conformance/diagnostics/method-changes-const.em` |
| A `const` class binding still allows changing the object's `var` fields | `conformance/run/classes.em`, `conformance/diagnostics/class-mutability.em` |
| A struct method that assigns `self` (directly or through another method) counts as mutation | `conformance/diagnostics/method-changes-const.em`, `conformance/diagnostics/method-changes-const-field.em` |
| A `const`-mutation diagnostic suggests `var` | `conformance/diagnostics/const-reassignment.em`, `conformance/diagnostics/type-field-read-only.em` |
| Reaching a binding while its changing method or setter runs is a runtime error | `conformance/runtime-errors/method-receiver-in-use.em`, `conformance/runtime-errors/setter-receiver-in-use.em` |
| Arguments and defaults are evaluated before the call takes the binding, so they may read it | `conformance/run/changing-method-arguments.em` |
| A default may not change `self` | `conformance/diagnostics/default-changes-self.em` |
| A changing method that raises still returns the receiver, with its changes visible | `conformance/run/errors.em` (`fail_after_change`) |
| A `const` field is assigned during construction and not later rebound | `conformance/diagnostics/const-field-assignment.em`, `conformance/diagnostics/const-field-assignment-nested.em` |
| List callbacks (equality, hashing, ordering, `remove_if`) may read the receiver; changing it raises `RuntimeError` naming list and method | `conformance/runtime-errors/list-callback-mutation.em`, `conformance/run/list-callback-equality.em`, `conformance/run/list-callback-hashing.em`, `conformance/run/list-callback-ordering.em`, `conformance/run/list-callback-paths.em` |
| Independent list value copies remain changeable inside those callbacks | `conformance/run/list-callback-paths.em` |
| `each` and `reduce` keep snapshot semantics | `src/emerald.zig: "a block traverses the list as it was, even when the block changes it"`, `conformance/run/list-reduce.em` |

## 4.4 Type relationships and conversion

| Rule | Covered by |
| --- | --- |
| Conditions require `Bool`; no truthiness | `conformance/diagnostics/condition-not-bool.em`, `src/emerald.zig: "a condition must be a Bool"` |
| Int widens to Float in arithmetic, declaration, assignment, argument, return, and literal element | `conformance/run/widening.em`, `conformance/run/typed-declarations.em` |
| Widening actually converts: `var rate: Float = 1` prints `1.0` | `conformance/run/typed-declarations.em` |
| Float does not narrow to Int | `src/emerald.zig: "Int widens to Float in a declaration but Float does not narrow"`, `src/Type.zig: "Int widens to Float but Float does not narrow"` |
| `to_int` raises, `to_int_or` falls back, `to_int_maybe` gives `Int?` | `conformance/run/string-methods.em`, `conformance/runtime-errors/not-a-number.em` |
| Mixed Int/Float comparison compares mathematical values without rounding the Int | `conformance/run/comparison.em`, `src/Value.zig: "a mixed comparison does not widen the integer first"` |
| Mutable collections are invariant | `conformance/diagnostics/list-invariance.em` |
| A mixed literal, `case`, or inline `if` of sibling classes infers the nearest shared base | `conformance/run/sibling-class-inference.em` (list, dictionary, `case`); inline `if`: **none** |
| Classes sharing only a trait are not inferred to the trait | **none** (`diagnostics/sibling-class-inference-unrelated.em` covers classes with no common ancestor, but not a shared trait) |
| `is` tests a runtime type and narrows within the proven branch | `conformance/run/type-tests.em` |
| `user?.name` gives an optional; when the receiver is `nothing` call arguments are not evaluated | `conformance/run/optional-object-reads.em` |
| Assignment through `?.` is rejected at check time | **none** |
| A struct's changing method through `?.` is rejected; a class's is allowed | `conformance/diagnostics/optional-chain-changing-method.em` |
| `is` known true warns when the type is already exactly the target | `conformance/diagnostics/redundant-type-test.em` |
| `is` known false warns for unrelated classes, and for a class and a trait no compatible class adopts | `conformance/diagnostics/impossible-type-test.em` |
| The tested expression is evaluated exactly once even when the result is known | `conformance/run/type-tests.em` |
| A trait-typed value, struct, or enum receives no false warning | **none** |
| Every value has `type_name`, spelled as source (`"Dog"`, `"List[Int]"`) | `conformance/run/type-tests.em` |
| `is` does not chain with a comparison; `not (value is Dog)` | `conformance/diagnostics/type-test-syntax.em` |
| `and`/`or` right sides are checked knowing the left side held or failed | `conformance/run/type-tests.em` |
| `type_name` is reserved: no member may be declared with it, and it cannot be assigned | `conformance/diagnostics/type-tests.em` |
| A tuple's `type_name` and `is` look at each held object's class | `conformance/run/type-tests.em` |
| A collection's `type_name` uses its static type | **none** (no case prints `type_name` of a `List[Animal]` holding a `Dog`) |

## 4.5 Optional handling

| Rule | Covered by |
| --- | --- |
| `.or(fallback)` supplies a value for absence | ``src/emerald.zig: "section 4.5: `or` supplies the value to use when there is none"`` |
| Comparison with `nothing` narrows a stable local | ``src/emerald.zig: "section 4.5: comparison with `nothing` narrows"`` |
| A mutable property is not narrowed between reads | **none** |
| Narrowing is lost on reassignment | `conformance/diagnostics/narrowing-invalidated-by-assignment.em`, `conformance/diagnostics/narrowing-undone-in-loop.em`, `conformance/diagnostics/narrowing-undone-in-if.em` |
| Narrowing is lost when a called closure could reassign the captured binding | `conformance/diagnostics/optional-narrowing-lost.em` |
| A module variable any function assigns is not narrowed; a `const` copy is | `conformance/diagnostics/narrowing-lost-to-function.em` |
| Inside a block, a captured variable that is ever reassigned keeps its declared type | `conformance/diagnostics/narrowing-lost-to-block.em` |
| `user?.address.city` is rejected when `address` may be absent | `conformance/diagnostics/optional-field-path.em`, `conformance/diagnostics/nested-optional-field-path.em` |
| `??` is rejected | `conformance/diagnostics/foreign-optional-default.em` |
| A literal containing `nothing` needs contextual element type | `conformance/diagnostics/optional-list-needs-type.em`, ``src/emerald.zig: "section 4.5: a literal mixing `nothing` needs its type from context"`` |
| A function returning `nothing` on some paths needs an explicit optional return type | **none** |
| A function never acquires an implicit `nothing` by falling off the end | `conformance/diagnostics/missing-return-path.em` |
| `Int??` is an error that suggests the single `?` | `conformance/diagnostics/optional-nested.em` |
| An optional-producing operation on an optional type yields that same type (no second layer) | **none** (no case looks up a `Dict[K, V?]` or `find`s in a `List[T?]`) |

## 5.1 Literals

| Rule | Covered by |
| --- | --- |
| Underscores separate digits but may not lead, trail, or repeat | `conformance/diagnostics/malformed-number.em`, `src/Lexer.zig: "underscores may not repeat or trail"`, `src/emerald.zig: "underscores in a literal carry no value"` |
| A decimal point or exponent makes a Float; exponents may be signed | `conformance/lexical/numbers.em`, `src/Lexer.zig: "integers and floats"` |
| `0x`, `0o`, `0b` get one targeted diagnostic | `conformance/diagnostics/non-decimal-base.em`, `src/Lexer.zig: "unsupported bases get one targeted diagnostic"` |
| A malformed literal reports one error spanning the attempted token | `src/Lexer.zig: "a malformed literal spans the whole attempted token"` |
| Double quotes process escapes and interpolation; `\#{` is literal | `conformance/run/string-literals.em` |
| Single quotes are raw | `conformance/run/string-literals.em`, `src/Lexer.zig: "a raw string processes no escapes"` |
| Triple quotes: opening newline omitted, closing indentation removed, no trailing newline | `conformance/run/multiline-strings.em` |
| Text must start on the line after `"""` and the closing `"""` needs its own line | `src/emerald.zig: "a triple-quoted string removes the closing delimiter's indentation"` |
| A content line indented less than the closing delimiter is an error, except a blank one | `conformance/diagnostics/multiline-indentation.em` |
| Indentation is removed before escapes, so an escaped `\n` is not a line break | **none** |
| A Windows line ending in a triple-quoted string becomes `\n` | `src/emerald.zig: "a triple-quoted string removes the closing delimiter's indentation"` |
| The escape set `\n \t \r \0 \\ \" \' \#` and `\u{1-6 hex}`; others are reported | `conformance/diagnostics/unknown-escape.em`, `src/Lexer.zig: "recognized escapes are accepted and others are reported"`, `src/emerald.zig: "string literals: escapes, raw strings, and code points"` |
| An interpolation may hold any expression, including a string with interpolations | `src/emerald.zig: "interpolation displays any value, and strings inside lists are quoted"` |

## 5.2 Boolean and comparison operators

| Rule | Covered by |
| --- | --- |
| `!`, `&&`, `\|\|` are not a second spelling | `conformance/diagnostics/foreign-logical-operators.em`, `conformance/diagnostics/bang-operator.em` |
| Chained comparison evaluates the middle once and short-circuits | `conformance/run/comparison.em`, `src/emerald.zig: "a chained comparison short-circuits before evaluating the next operand"` |
| `==`/`!=` need the same type, or Int with Float | `src/emerald.zig: "values of different kinds cannot be compared or added"` |
| Ordering applies only to numbers and strings; `true < false` is rejected | `conformance/diagnostics/ordering-non-numbers.em` |
| `if x = 5` is rejected | `conformance/diagnostics/assignment-in-condition.em` |
| Chained assignment is rejected | `src/emerald.zig: "assignment is a statement and cannot be chained"` |
| Compound assignment evaluates receiver and index once, reads, then evaluates the right side | **none** (no case observes the order or single evaluation of a compound assignment's index) |
| Arguments evaluate left to right | `conformance/run/print-arguments.em`, `src/emerald.zig: "print evaluates every argument before writing any of them"` |
| A standalone pure expression is an error suggesting `score += 1` | `conformance/diagnostics/unused-result.em` |

## 5.3 Arithmetic

| Rule | Covered by |
| --- | --- |
| `**` binds tighter than unary minus and is right-associative | `conformance/run/precedence.em`, `src/emerald.zig: "exponentiation binds tighter than unary minus and associates right to left"` |
| A `-` against a number is part of it: `-3.abs()` is `3`, `-3.positive?()` is `false` | `conformance/run/negative-literals.em` |
| `- 3.abs()` (spaced) is `-(3.abs())`; `-x.abs()` negates the absolute value | `conformance/run/negative-literals.em` |
| `x -3` is subtraction | **none** (`run/adjacent-minus.em` covers `c--1`, not `x -3`) |
| The formatter writes `-3.abs()`, keeps `(-2) ** 2`, prints spaced negation as `-(3.abs())` | `conformance/format/operator-precedence.em`, `src/Formatter.zig: "a negative number keeps its parentheses before a power"` |
| Overflow raises and names the operation and both operands | `conformance/runtime-errors/integer-overflow.em`, `src/emerald.zig: "integer overflow is reported rather than wrapping"` |
| Compound assignment checks overflow | **none** |
| Negating the minimum `Int` overflows | `conformance/runtime-errors/negate-minimum-int.em` |
| Division by zero is an error for both numeric types | `conformance/runtime-errors/division-by-zero.em`, `src/emerald.zig: "division by zero is an error for both numeric types"` |
| Float overflow gives infinity | `conformance/run/float-display.em` (`1e308 * 10`) |
| NaN follows IEEE comparison and is inspected with `nan?()` | `src/emerald.zig: "NaN follows IEEE comparison behavior"`, `conformance/run/float-methods.em` |
| NaN is invalid as a dictionary key or set element, directly or recursively | `conformance/runtime-errors/nan-key.em`, `src/Interpreter.zig: "a NaN nested in a struct is detected for key rejection"` |
| Sorting, `min`, `max` raise on NaN | `conformance/runtime-errors/list-sort-nan.em`, `conformance/runtime-errors/list-min-max-nan.em`, `conformance/runtime-errors/list-extrema-nan.em` |
| Infinity orders normally | `conformance/run/list-extrema.em` |
| `/` always returns Float | `conformance/run/division.em` |
| `//` rounds toward negative infinity; a Float operand gives a whole Float | `conformance/run/division.em` |
| `%` follows the floor law and takes the divisor's sign | `conformance/run/division.em` |
| `%` with a Float operand returns Float | **none** |
| A NaN or infinite remainder operand produces NaN | **none** |
| `**` on two Ints is an overflow-checked Int; a Float operand gives Float | `conformance/run/exponentiation.em`, `src/emerald.zig: "exponentiation of two Ints is an Int, and a Float operand makes a Float"` |
| A negative Int exponent raises and suggests a Float base | `conformance/runtime-errors/negative-exponent.em` |
| Compound assignment `+= -= *= /= //=` lowers through its binary operator | `conformance/run/bindings.em`, `conformance/diagnostics/compound-divide.em` |
| `++` and `--` are omitted | `conformance/diagnostics/foreign-increment.em`, `conformance/diagnostics/foreign-decrement.em` |

## 5.4 Calls, member access, and indexing

| Rule | Covered by |
| --- | --- |
| Out-of-range indexing is an error naming the index and the valid range | `conformance/runtime-errors/index-out-of-range.em` |
| Lists and strings slice with `..<`, `..`, `i..<`, `..<j`, producing independent values | `conformance/run/range-slicing.em` |
| String slice boundaries count graphemes | `conformance/run/range-slicing.em` |
| An endpoint outside the valid boundaries is an error, not clamped | `conformance/runtime-errors/slice-endpoints.em` |
| A slice start after its end is an error, not an empty result | **none** |
| An exclusive endpoint may equal the length; `items[i..<i]` is empty | `conformance/run/range-slicing.em` |
| A dictionary does not slice; a parenthesized `Range` as an ordinary index is a type error | `conformance/diagnostics/slice-types.em` |
| A bound method value from a struct keeps its own evolving copy | `conformance/run/method-values.em` |

## 6.1 Blocks and scope

| Rule | Covered by |
| --- | --- |
| A local declared in a block does not leak out | `conformance/diagnostics/undefined-name.em`, `src/emerald.zig: "a local does not leak out of its block"` |
| A loop variable is fresh per iteration, so closures capture that iteration's value | `src/emerald.zig: "section 6.1: a loop variable is fresh each iteration, so blocks keep their own"` |
| Shadowing a visible local in the same function is an error, including across a block | `conformance/diagnostics/shadowing.em` |
| Sibling scopes may reuse a name | `src/emerald.zig: "sibling scopes may reuse a name"` |
| A parameter or local may reuse a module-level name | `conformance/run/module-scope.em`, `src/emerald.zig: "crossing a function boundary allows reusing a module-level name"` |

## 6.2 Conditional statements and expressions

| Rule | Covered by |
| --- | --- |
| `if` / `else if` / `else` select one branch | `conformance/run/conditionals.em` |
| The expression form requires both answers | `conformance/diagnostics/if-expression-missing-else.em`, `conformance/diagnostics/if-expression-missing-then.em` |
| Its condition must be `Bool`, runs once, and only the chosen answer runs | `conformance/run/if-expression.em`, `conformance/diagnostics/if-expression.em` |
| Both answers are checked, with the condition's narrowing in the matching answer | `conformance/run/if-expression.em`, `conformance/diagnostics/if-expression-unselected-name.em`, `src/emerald.zig: "inline if records mutations in either answer and merges narrowing"` |
| Result types: Int/Float give Float, a `nothing` answer makes it optional, siblings infer their base | `conformance/run/if-expression.em` (Int/Float, `nothing`); sibling classes: **none** |
| An expected collection or function type flows into both answers | `conformance/run/if-expression.em` |
| Each answer is a full expression: `if r then 1 else 2 + 3` adds only in `else` | `conformance/run/if-expression.em`, `conformance/format/if-expression.em` |
| `return if c then a else b` returns a value; `return if c` stays a guard | `src/emerald.zig: "inline if returns a value without changing the meaning of a return guard"` |
| A trailing `if` guards one simple statement and has no `else` | `conformance/run/trailing-if.em`, `src/emerald.zig: "a trailing if guards one statement"` |
| A declaration cannot take a trailing `if` | `conformance/diagnostics/guarded-declaration.em`, `src/emerald.zig: "a declaration cannot have a trailing if"` |
| There is no `unless` (it is not a keyword or construct) | **none** (`run/trailing-if.em` mentions it only in a comment) |

## 6.3 `case` and `when`

| Rule | Covered by |
| --- | --- |
| The subject is evaluated once; alternatives are tested top to bottom with `==`; first match runs; no fall-through | `conformance/run/case.em` |
| Commas give several alternatives in one arm | `conformance/run/case.em` |
| A statement case may omit `else`; no match does nothing | `conformance/run/case.em` |
| A value-producing case uses `then` and must be exhaustive | `conformance/diagnostics/case.em` |
| A subjectless `case` takes one `Bool` condition per `when`, joined with `or`, not commas | `conformance/run/case.em`, `conformance/diagnostics/case-syntax.em` |
| Each arm is checked knowing its condition held and earlier ones failed | `conformance/run/case.em` (subjectless arms read the narrowed `reading`) |
| Value-producing enum cases may omit `else` when every value is covered | `conformance/run/case.em`, `conformance/run/enums.em` |
| A nonexhaustive enum statement case is a warning unless `else` acknowledges it | `conformance/run/warning-does-not-block-execution.em`, `conformance/diagnostics/enum-data-match-check.em` |
| A nonexhaustive `Bool` statement case is a warning | **none** |
| An `Int` or `String` subject gets no exhaustiveness warning | `conformance/run/case.em` (`case "tea"` with no `else`, no warning) |
| An explicit empty `else { }` acknowledges the gap | **none** |
| Known duplicate alternatives are errors; `when 1.0` repeats `when 1` | `conformance/diagnostics/case.em` |
| Every arm has the same form; a block case in value position, or an unused `then` case, is an error | `conformance/diagnostics/case-syntax.em` |
| Alternatives are evaluated only until one matches | `conformance/run/case.em` (`traced`) |
| Coverage is known for enums, `Bool`, and `nothing`; `when nothing` matches absence | `conformance/run/case.em` |
| A statement case that covers every value counts as complete for returns and definite assignment | `conformance/run/case.em` (`Light`) |
| Value arms agree on a type: Int and Float give Float, a `nothing` arm makes it optional | `conformance/diagnostics/case.em`, `conformance/run/case.em` |
| Each arm has its own lexical scope | **none** |

## 6.4 Loops

| Rule | Covered by |
| --- | --- |
| `break` exits and `continue` restarts the innermost loop | `conformance/run/loops.em`, `src/emerald.zig: "break and continue act on the innermost loop"` |
| `break`/`continue` outside a loop is an error | `conformance/diagnostics/break-outside-loop.em` |
| Loop bindings are read-only and fresh every iteration | `conformance/diagnostics/loop-variable-read-only.em` |
| Range endpoints are evaluated once before iteration | `src/emerald.zig: "range endpoints are evaluated once, before the first iteration"` |
| `for _ in 1..3` repeats without naming the value | `src/emerald.zig: "an underscore visits each value without naming it"` |
| A name assigned only inside a loop is not known after it, and the diagnostic says the loop might not run | `conformance/diagnostics/assigned-in-loop.em` |
| After `while true`, a name is assigned when every `break` assigned it | `conformance/run/loop-assignment.em`, `src/emerald.zig: "after while true, a name is assigned when every break assigned it"` |
| A function may end in a `while true` that only `return` leaves | `src/emerald.zig: "a function may end in a loop that only a return leaves"` |
| Only a literal `true` counts for that rule | **none** |
| `..` includes both bounds, `..<` excludes the upper; ranges count only upward; start past end is empty | `conformance/run/counting.em`, `src/emerald.zig: "a for loop visits a range in order, and a range only counts upward"` |
| `down_to`, `up_to`, `step`, and `reverse` count as written | `conformance/run/counting.em`, `src/emerald.zig: "counting down, stepping, and reversing say their direction in words"` |
| A target on the wrong side counts nothing (`count.down_to(1)` with `count` 0) | `src/emerald.zig: "a computed count on the wrong side is empty, so walking backwards is safe"` |
| The block forms `5.down_to(1) { ... }` and `1.up_to(5) { ... }` run the same count | `src/emerald.zig: "integer counting block forms use the same Range semantics"` |
| A Range is an immutable value with `count`, `empty?()`, and `to_list()` | `conformance/run/range-values.em`, `src/emerald.zig: "ranges are immutable values that can be stored, passed, and iterated"` |
| `count` of the full `Int` domain raises with a correction | `src/emerald.zig: "a full-domain Range never truncates its count"` |
| Materializing the full `Int` domain with `to_list()` raises | **none** |
| `step` takes a distance of at least 1; a count takes at most one `step` | `conformance/diagnostics/step-below-one.em`, `src/emerald.zig: "a step is at least 1 and given once"` |
| A computed step below 1 raises when the loop begins | `src/emerald.zig: "a step is at least 1 and given once"` (`step(n)` with `n = -2`) |
| `step` and `reverse` apply in the order written | `src/emerald.zig: "reverse and step apply in the order written"` |
| A count written with two literals that can only be empty (`5..1`, `1.down_to(5)`) is an error suggesting the other direction | `conformance/diagnostics/descending-range.em`, `src/emerald.zig: "a count written with literals that can only be empty is an error"` |
| Computed endpoints are never reported | `src/emerald.zig: "a computed count on the wrong side is empty, so walking backwards is safe"` |
| Equal inclusive endpoints visit once in every form; an equal half-open range is empty | `src/emerald.zig: "ranges are immutable values that can be stored, passed, and iterated"` (`0..<0` is empty); equal inclusive endpoints visiting once: **none** |
| A Range prints in its inclusive form; a step keeps its parentheses; descending uses `down_to` | `conformance/run/range-display.em` |
| An empty range prints with its own bounds, never as `[]` | `conformance/run/range-display.em` |
| Every empty range equals every other | `conformance/run/range-display.em` |
| The Int block forms return `Nothing` | `src/emerald.zig: "integer counting block forms use the same Range semantics"` |
| `times` visits `0` through `n - 1` and rejects a negative count | `src/emerald.zig: "integer counting block forms use the same Range semantics"` |
| The wrong-side rule applies to `up_to`/`down_to` block forms | **none** |
| Counting reaches both ends of the Int range without overflow | `src/emerald.zig: "counting reaches both ends of the Int range without overflowing"`, `src/Range.zig: "range reaches exactly reachable endpoints without overflow"` |

## 6.5 Returns and guards

| Rule | Covered by |
| --- | --- |
| `return` inside a lambda leaves only the lambda | `src/emerald.zig: "return leaves only the lambda, and break cannot leave one at all"` |
| A function with no value has type `Nothing`, written or omitted, and may use bare `return` | `src/emerald.zig: "a function with no result may omit its return type"` |
| A recursive function returning a value needs an explicit return type | `conformance/diagnostics/recursive-needs-return-type.em`, `src/emerald.zig: "a recursive function needs an explicit return type"` |
| A statement after one that cannot complete is a warning, once, at the first such statement | `conformance/diagnostics/error-checking.em`, `conformance/diagnostics/top-level-return.em`, `conformance/run/warning-does-not-block-execution.em` |
| The warning also follows an `if`/`case` every branch of which cannot complete | **none** |
| A nested function declared after a `return` is not unreachable | **none** |

## 7.1 Declaration

| Rule | Covered by |
| --- | --- |
| `->` is not part of the callable surface | **none** |
| Function types reuse declaration syntax (`func(Int): String`) | `src/emerald.zig: "a function type is written the way a declaration is"` |
| Mutating a collection or struct parameter is rejected, and the diagnostic says the change would be lost | `conformance/diagnostics/parameter-list-mutation.em`, `conformance/diagnostics/method-changes-parameter.em` |
| A class object received as a parameter may be mutated, visibly to the caller | `conformance/run/classes.em` |
| Assigning to any parameter is an error | `conformance/diagnostics/parameter-read-only.em`, `src/emerald.zig: "parameters are read-only and share the body's scope"` |
| Functions are hoisted; variables are visible only from their declarations | `conformance/diagnostics/declared-later.em`, `src/emerald.zig: "functions are hoisted, so a call may come before the declaration"` |
| Nested named functions capture surrounding bindings and are hoisted within their block | `src/emerald.zig: "a nested function is hoisted within its block and shares its variables"`, `conformance/diagnostics/nested-function-captures.em` |
| Hoisting never permits reading an uninitialized captured variable | `conformance/diagnostics/capture-before-assignment.em`, `src/emerald.zig: "hoisting never permits reading an uninitialized captured variable"` |
| A use of a nested function is checked through the nested functions it calls | `conformance/diagnostics/nested-function-before-declaration.em` |
| A nested function shares its enclosing function's name space | `conformance/diagnostics/nested-function-before-declaration.em` (`func name` beside `var name`) |
| A nested function may not use `self` | **none** |
| A nested function takes defaults and named arguments | **none** |

## 7.2 Inference and annotations

| Rule | Covered by |
| --- | --- |
| Lambda parameter types are inferred from the expected callable type or the receiving method | `src/emerald.zig: "a lambda takes its parameter types from the type expected where it is written"` |
| A non-recursive function's return type is inferred from its body | `src/emerald.zig: "a return type is inferred from a non-recursive body"` |
| Incompatible returns make an inferred type ambiguous | `src/emerald.zig: "incompatible returns make an inferred type ambiguous"` |
| Every reachable path in a value-producing function returns | `conformance/diagnostics/missing-return-path.em` |
| Mutually recursive functions returning a value need explicit return types | `src/emerald.zig: "recursion and mutual recursion run when annotated"` |
| A recursive function with no result needs no annotation | `src/emerald.zig: "a recursive function with no result needs no annotation"` |
| Calling a no-result function produces `nothing` | `src/emerald.zig: "a call with no result evaluates to nothing"` |
| At least 1,000 active calls are supported | `src/emerald.zig: "a body nested 250 deep still supports 1,000 calls"`, `conformance/runtime-errors/recursion-limit.em` |
| Crossing the limit raises a catchable `RecursionError`, with `finally` still running | `conformance/run/recursion-error.em` |
| The report names the repeating call and summarizes repeated frames | `conformance/runtime-errors/recursion-limit.em`, `src/emerald.zig: "unbounded recursion is caught at the limit, with repeated frames summarized"` |

## 7.3 Defaults and named arguments

| Rule | Covered by |
| --- | --- |
| A second declaration of a function name in one scope is an error naming the first | `conformance/diagnostics/duplicate-in-namespace` (across files); same file: **none** |
| Defaulted parameters follow required ones | `conformance/diagnostics/default-before-required.em` |
| One required function-typed parameter may follow defaulted ones, for a trailing block | `conformance/run/trailing-block-after-named-arguments.em` |
| Named arguments may skip defaults | `conformance/run/defaults-and-named-arguments.em` |
| A call may not supply a parameter twice or put positional arguments after named ones | `conformance/diagnostics/argument-matching.em` |
| A trailing block fills the final parameter whatever was named | `conformance/run/trailing-block-after-named-arguments.em`, `src/arguments.zig: "a trailing block fills the final parameter after named ones"` |
| Explicit arguments evaluate left to right as written, then omitted defaults in parameter order | `conformance/run/defaults-and-named-arguments.em` |
| A default may read earlier parameters but not itself or later ones | `conformance/diagnostics/default-reads-later-parameter.em` |
| An override inherits its base default and cannot replace it | `conformance/diagnostics/inheritance-overrides.em`, `conformance/run/inheritance-project` |
| A same-named subclass member without `@override` is a diagnostic | `conformance/diagnostics/inheritance-overrides.em` |
| Users cannot write variadic functions | **none** |

## 7.4 Lambdas, trailing blocks, and capture

| Rule | Covered by |
| --- | --- |
| A single-expression lambda returns its expression; a block body uses `return` | `src/emerald.zig: "a lambda body on more than one line returns its result"`, `src/emerald.zig: "a one-line lambda body may be a statement rather than a value"` |
| A zero-argument lambda keeps the arrow | `conformance/diagnostics/lambda-no-arrow.em` |
| Standalone lambda parameters need types | `conformance/diagnostics/lambda-needs-type.em` |
| `_` discards an argument and may appear more than once | ``src/emerald.zig: "section 7.4: `_` takes a value without naming it, more than once"`` |
| Tuple destructuring in lambda parameters is checked for shape and arity, and names are read-only | `conformance/diagnostics/nested-unpacking-mismatch.em`, `conformance/diagnostics/lambda-arity.em`, `conformance/run/nested-unpacking.em` |
| A dictionary entry is one tuple item, not two parameters | `conformance/run/dictionaries.em` |
| A bare capture of a higher-order method whose output type depends on a block needs an expected callable type | **none** |
| Closures capture by reference, both ways | `conformance/run/closures.em`, `src/emerald.zig: "section 7.4: capture is by reference, so the variable is shared both ways"` |
| A module lambda may capture a later module variable if called after it is assigned; calling earlier is an error | `conformance/run/module-lambda-capture.em`, `src/emerald.zig: "a module lambda checks its captures when it is called, not when it is created"` |
| `break`/`continue` cannot reach out of a lambda | `conformance/diagnostics/break-in-lambda.em`, `conformance/diagnostics/lambda-loop-exits.em` |
| A struct method may not create a closure that mutates its `self`; class methods may capture `self` | `conformance/diagnostics/self-in-block.em`, `conformance/run/classes.em` |
| A trailing lambda in an `if`/`while`/`for` header needs parentheses; the diagnostic offers both corrections | `conformance/diagnostics/block-in-header.em`, `src/emerald.zig: "section 7.4: a trailing block in a control-flow header needs parentheses"` |

## 7.5 Method values

| Rule | Covered by |
| --- | --- |
| `player.greet` captures the method; class receivers stay shared | `conformance/run/method-values.em` |
| A struct receiver is copied, and the captured copy keeps its changes across calls | `conformance/run/method-values.em` |
| Calling the same captured method again from inside that call is a runtime error | `conformance/runtime-errors/captured-method-called-again.em` |
| Capturing a method of `self` in a constructor waits until every field is set; a field default cannot capture one | `conformance/diagnostics/method-value-before-ready.em` |
| Two captured methods are equal only when they are the same captured value | `conformance/run/method-values.em` |

## 8.1 Design

| Rule | Covered by |
| --- | --- |
| Lists, dictionaries, and sets are values: assignment and passing give independent copies | `conformance/run/list-values.em`, `conformance/run/collection-mutation-copies.em`, `src/emerald.zig: "section 8.1 gives a dictionary and a set value semantics"` |
| A `const` collection and a collection parameter cannot change | `src/emerald.zig: "a const, a parameter, a loop variable, and a temporary cannot change"`, `src/emerald.zig: "section 8.1 gives a dictionary and a set value semantics"` |
| Copies share storage until one is mutated (copy-on-write) | `src/Heap.zig: "a shared buffer is copied before it changes, and a sole one is not"`, `src/Heap.zig: "a shared dictionary is copied before it changes"` |

## 8.2 Surface syntax

| Rule | Covered by |
| --- | --- |
| A dictionary literal is recognized by `key: value` entries | `src/emerald.zig: "section 8.2's dictionary literal, lookup, and assignment"` |
| A bracketed list is a set only where a set type is expected | `conformance/run/sets.em`, `src/emerald.zig: "section 8.2's set literal is bracketed where a set is expected"` |
| Without an expected set type, a bracketed list is a list; `.to_set()` converts | `conformance/diagnostics/set-literal-needs-set-type.em` |
| A parameter type supplies the expected set type (`colors.union(["blue"])`) | `conformance/run/set-operations.em` |
| Empty literals need an explicit type | `conformance/diagnostics/empty-list-needs-type.em`, `src/emerald.zig: "section 8.2's empty literals take their kind from the expected type"` |
| A list in a binding stays a list: `var seen: Set[String] = names` is an error correcting to `to_set()` | `src/emerald.zig: "section 8.2's set literal is bracketed where a set is expected"` |
| A dictionary prints `["Ava": 12]`, an empty one `[:]`; a set prints `{"red"}`, an empty one `{}` | `src/emerald.zig: "section 8.2's empty literals take their kind from the expected type"`, `conformance/run/dictionaries.em` |
| Braces in expression position are always a lambda | `src/emerald.zig: "a lambda is a value that can be called"` (indirect); a list literal in a `for` header needing no grouping: `src/emerald.zig: "section 8.4 visits a dictionary and a set in insertion order"` |
| Tuples need at least two elements; `(value)` and `(value,)` are groups; `()` is not a value | `src/emerald.zig: "section 8.2 needs at least two positions, so one is a group"`, `conformance/diagnostics/empty-tuple.em` |
| Tuple positions use `.0`, `.1`; an invalid position is a compile-time error | `conformance/diagnostics/tuple-position.em`, `src/emerald.zig: "a tuple position is checked where it is written"` |
| A tuple has no `count` | `conformance/diagnostics/tuple-has-no-count.em` |
| `entry.0.1` reaches a position of a position | `conformance/run/tuples.em`, `src/emerald.zig: "section 8.2's tuple literal, and its positions"` |
| A tuple cannot be assigned to a position | `conformance/diagnostics/tuple-position-assignment.em` |
| Tuples widen position by position: `(Int, Int)` where `(Float, Int)` is expected | `conformance/run/tuples.em`, `src/emerald.zig: "section 4.4 widens a tuple position wherever one is expected"` |
| Destructuring must match the arity, in declarations, `for`, block parameters, and assignment | `conformance/diagnostics/tuple-arity.em`, `conformance/diagnostics/nested-unpacking-mismatch.em`, `src/emerald.zig: "unpacking checks the shape before it binds anything"` |
| A position may itself be unpacked, everywhere | `conformance/run/nested-unpacking.em` |
| `_` discards a position | `src/emerald.zig: "section 8.2 unpacks a tuple wherever names are introduced"` |
| Assignment unpacking evaluates the complete right side first | `src/emerald.zig: "section 8.2's assignment unpacking evaluates the right side first"` |
| Assignment targets are mutable local names or `_`; fields and indexes are not yet targets | `conformance/diagnostics/tuple-assignment-target.em` |

## 8.3 Indexing and dictionary misses

| Rule | Covered by |
| --- | --- |
| Negative indexes are errors, not from-the-end | `src/emerald.zig: "an index outside the list names the index and the valid range"` (`xs[-1]`) |
| Dictionary lookup produces an optional | `conformance/run/dictionaries.em`, `src/emerald.zig: "section 8.2's dictionary literal, lookup, and assignment"` |
| Bracket assignment inserts or replaces | `src/emerald.zig: "section 8.2's dictionary literal, lookup, and assignment"` |
| A compound assignment needs an entry that is already there | `src/emerald.zig: "a compound assignment needs an entry that is already there"`, `conformance/runtime-errors/missing-entry.em` |
| An optional-valued dictionary reads a stored `nothing` and a miss alike, and `contains_key?` tells them apart | **none** |
| Assigning `nothing` stores an entry and never deletes | **none** |
| Keys need stable equality and hashing; scalars, strings, enums, and qualifying structs and tuples are keys | `conformance/run/dictionary-keys.em`, `conformance/diagnostics/dictionary-key-eligible.em` |
| An optional is not a key | `src/emerald.zig: "section 8.3 accepts only keys that can be found again"` |
| A set's members follow the same rule | `conformance/diagnostics/set-eligible.em` |
| Stored value-type keys are copied, so later mutation of the original cannot break lookup | **none** |
| Classes and collections are not keys | `conformance/diagnostics/dictionary-key-eligible.em`, `conformance/diagnostics/class-mutability.em`, `src/emerald.zig: "section 8.3 accepts only keys that can be found again"` |
| A `Hashable` struct is a key through its own `equals`/`hash` | `conformance/run/equatable-and-hashable.em` |
| An `Equatable` struct without `Hashable` is not a key, with that reason named | `conformance/diagnostics/equatable-without-hashable-key.em` |
| `Hashable` does not make a class a key | **none** |

## 8.4 Equality and order

| Rule | Covered by |
| --- | --- |
| `Equatable` replaces `==`; `!=` is always `not equals` | `conformance/run/equatable-and-hashable.em` |
| Declaring `equals` or `hash` without adopting the trait is a warning, not a behavior change | `conformance/diagnostics/equatable-hash-without-adoption.em` |
| Lists compare in order, sets by membership, dictionaries by contents, tuples by position | `conformance/run/lists.em`, `src/emerald.zig: "section 8.4 compares a dictionary by contents and a set by membership"`, `src/emerald.zig: "section 8.4 compares tuples position by position"` |
| Dictionaries and sets iterate in insertion order | `src/emerald.zig: "section 8.4 visits a dictionary and a set in insertion order"`, `conformance/run/dictionaries.em` |
| Replacing a value keeps its position; removing and reinserting moves it to the end | `src/Heap.zig: "a dictionary keeps insertion order, and a replaced value keeps its place"` (runtime level only; no Emerald-level case) |
| A `for` loop iterates the snapshot taken when it begins | `src/emerald.zig: "a loop visits the list as it was when the loop began"` (lists); dictionaries and sets: **none** |
| Repeated set-literal elements collapse to one | `src/emerald.zig: "section 8.2's set literal is bracketed where a set is expected"` |
| A statically known duplicate dictionary-literal key is an error | `conformance/diagnostics/dictionary-duplicate-keys.em` |
| Runtime-colliding calculated keys: the later value wins without moving | **none** |

## 8.5 Essential methods

| Rule | Covered by |
| --- | --- |
| `count` is a read-only property; `first` and `last` are properties | `conformance/run/lists.em`, `conformance/run/optionals.em` |
| `remove(element)` removes the first equal value and does nothing when absent; `remove_all` removes every one | `src/emerald.zig: "the essential list methods"` |
| `remove_at`, `remove_first`, `remove_last` return the element and raise on an empty list | `src/emerald.zig: "the essential list methods"`, `conformance/runtime-errors/remove-from-empty.em` |
| `insert(index, element)` accepts `0` through `count`; past `count` is an error | `src/emerald.zig: "the essential list methods"`, `src/emerald.zig: "an index outside the list names the index and the valid range"` |
| `append_all(items)` reads its argument first, so `items.append_all(items)` doubles once | `conformance/run/list-append-all-self.em` |
| Mutating methods are rejected on a `const`, parameter, loop variable, or temporary | `src/emerald.zig: "a const, a parameter, a loop variable, and a temporary cannot change"`, `conformance/diagnostics/temporary-list-mutation.em` |
| A list displays as written: `[1, 2, 3]`, `[[1.0], []]` | `src/emerald.zig: "lists compare element by element and print as they are written"` |
| Dictionary vocabulary: `contains_key?`, `contains_value?`, `keys`, `values`, `entries`, `remove`, `merge` | `src/emerald.zig: "section 8.5's dictionary vocabulary"`, `conformance/run/dictionaries.em` |
| Set vocabulary: `add`, `remove` | `src/emerald.zig: "section 8.5's set vocabulary"` |

## 8.6 Rich vocabulary

| Rule | Covered by |
| --- | --- |
| Set operations use names; comparison operators do not mean subset | `conformance/run/set-operations.em` (names); operators rejected: **none** |
| A dictionary block receives one `(key, value)` tuple; `each_with_index` adds the index | `conformance/run/dictionaries.em` |
| `map_keys` and `map_values` receive only their part | `conformance/run/dictionary-map-transform.em` |
| Transformations run blocks left to right once per item and preserve order | `conformance/run/lists.em`, `conformance/run/dictionary-set-filtering.em` |
| `find`, `any?`, `all?`, `none?`, `one?` stop as soon as the answer is known | `conformance/run/lists.em` |
| `range.map` returns a completed list | **none** |
| `each` returns `Nothing` | `conformance/diagnostics/each-result-unused.em` |
| `reduce` takes a required initial value, which sets the accumulator type; empty input returns it | `conformance/run/list-reduce.em`, `conformance/diagnostics/list-reduce.em` |
| `reduce_right` visits from the end | `conformance/run/list-reduce-right.em` |
| Changing a captured binding during `reduce` does not change the items reduced | `conformance/run/list-reduce.em` |
| `filter_map` keeps present values; a non-optional block is rejected toward `map`; a present List is not flattened | `conformance/run/list-filter-map.em`, `conformance/diagnostics/list-filter-map.em` |
| `filter` and `reject` keep the receiver's kind for lists, dictionaries, and sets | `conformance/run/dictionary-set-filtering.em`, `conformance/run/lists.em` |
| `take`/`drop` keep the receiver's kind for dictionaries and sets, in insertion order | **none** |
| `take`/`drop` on a range return a list | **none** |
| A negative `take`/`drop` is an error; a count past the end is not | `conformance/runtime-errors/list-portions.em`, `conformance/run/lists.em` |
| `take`, `drop`, `reverse`, `unique` return new lists; `reverse!`/`unique!` change the list; `unique` keeps first occurrences | `conformance/run/lists.em`, `conformance/run/collection-mutation-copies.em` |
| The non-bang forms work on a `const`; bang forms need a changeable list | **none** (no diagnostic case calls `sort!`, `reverse!`, `unique!`, or `shuffle!` on a `const`) |
| `each_with_index` and `reverse_each` on lists, dictionaries, and sets | `conformance/run/lists.em`, `conformance/run/dictionaries.em`, `conformance/run/sets.em`, `conformance/diagnostics/each-with-index.em`, `conformance/diagnostics/reverse-each.em` |
| `any?`, `all?`, `none?`, `one?`, `count_where` on an empty collection give `false`, `true`, `true`, `false`, `0` | `conformance/run/lists.em` |
| `one?` stops at its second accepted item | `conformance/run/lists.em` |
| `take_while`/`drop_while`: prefix rules, no predicate call after the first failure, empty list calls nothing | `conformance/run/lists.em` |
| `flat_map` needs a List per item, flattens one level, and rejects an optional List | `conformance/run/lists.em`, `conformance/diagnostics/list-flat-map.em` |
| `sum()` of an empty list is `0` or `0.0`; Int sum checks overflow; other element types get a correction | `conformance/run/list-sum.em`, `conformance/runtime-errors/list-sum-overflow.em`, `conformance/diagnostics/list-sum.em` |
| `join(separator = "")` needs `List[String]`, an empty list joins to `""`, and `List[String?]` is rejected | `conformance/diagnostics/list-join.em`, `conformance/run/string-text-tools.em` |
| `index_of` gives the first equal position or `nothing`, and needs `Equatable` for a `T` | `conformance/run/list-index-repeat-append.em`, `conformance/diagnostics/list-index-repeat-append.em` |
| `repeat(n)`: `0` gives `[]`, a negative count raises, and the copies are independent | `conformance/run/list-index-repeat-append.em`, `conformance/runtime-errors/list-repeat-negative.em` |
| `average()` gives `Float?`, `nothing` when empty, `[1, 2].average()` is `1.5` | `conformance/run/list-average.em` |
| `min()`/`max()` give the first tied extreme or `nothing`; optional elements are rejected; NaN raises | `conformance/run/list-extrema.em`, `conformance/diagnostics/list-extrema.em`, `conformance/runtime-errors/list-extrema-nan.em` |
| `min_by`/`max_by`: first tied item, NaN key raises, optional elements and keys rejected | `conformance/run/list-extrema-by.em`, `conformance/diagnostics/list-extrema-by.em`, `conformance/runtime-errors/list-extrema-by-nan.em` |
| `min_max()` returns `(T?, T?)`, `(nothing, nothing)` when empty | `conformance/run/list-min-max.em`, `conformance/runtime-errors/list-min-max-nan.em` |
| `sort()` is new and stable, `sort!()` changes and returns `Nothing`, NaN raises, optional elements rejected | `conformance/run/list-sort.em`, `conformance/run/sort-long-stable.em`, `conformance/runtime-errors/list-sort-nan.em`, `conformance/diagnostics/list-sort-and-associate.em` |
| `sort_by` computes one key per item, left to right; a NaN key raises | `conformance/run/list-sort.em`, `conformance/runtime-errors/list-sort-by-nan.em` |
| A comparison that raises partway leaves every item in the list | `conformance/run/list-callback-ordering.em` |
| `unique_by`, `associate`, `associate_by`, `to_dictionary`: a repeated key keeps its first position and takes the last value | `conformance/run/list-associate.em` |
| `zip`, `chain`, `chunks`, `windows`, `pairs` | `conformance/run/list-zip.em`, `conformance/run/list-shape.em`, `conformance/run/list-shape-result-types.em`, `conformance/diagnostics/list-shape-wrong-results.em` |
| `group_by`, `partition`, `frequencies` | `conformance/run/list-grouping.em` |
| Strings and tuples do not get the general collection operations | `conformance/diagnostics/string-unknown-member.em` (strings); tuples: **none** |

## 9.1 Unicode strings

| Rule | Covered by |
| --- | --- |
| Character operations use extended grapheme clusters | `conformance/run/unicode-text.em`, `src/unicode.zig: "grapheme clusters match every case in Unicode's GraphemeBreakTest"` |
| Zero-based indexing returns a grapheme | `src/emerald.zig: "count, indexing, and for measure characters, not bytes"` |
| Iteration yields grapheme strings | `src/emerald.zig: "count, indexing, and for measure characters, not bytes"` |
| `substring(start)` runs to the end; a start equal to `count` gives `""`; a zero count is valid | `src/emerald.zig: "the string vocabulary"`, `src/strings.zig: "substring counts characters and does not clamp"` |
| A negative argument, a start past the end, or a count past the end raises rather than clamping | `conformance/runtime-errors/substring-negative-start.em`, `conformance/runtime-errors/substring-past-end.em`, `src/strings.zig: "substring counts characters and does not clamp"` |

## 9.2 Initial string vocabulary

| Rule | Covered by |
| --- | --- |
| String methods do not mutate the receiver | `conformance/run/string-methods.em` |
| `capitalize()` uppercases the first grapheme and keeps the rest | `conformance/run/unicode-text.em`, `src/emerald.zig: "the string vocabulary"` |
| `capitalize()` returns an empty string unchanged | **none** |
| `count` measures graphemes; `index_of` returns an optional | `src/emerald.zig: "count, indexing, and for measure characters, not bytes"`, `conformance/run/optionals.em` |
| `lines()` drops `\n` and a `\r` before it; a final line ending adds no empty line | `conformance/run/string-methods.em`, `src/strings.zig: "split, replace, and lines"` |
| `insert_at(index, text)`: `0` through `count`; negative or past `count` is an error | `conformance/run/string-methods.em`, `conformance/runtime-errors/insert-at-past-count.em`, `src/strings.zig: "string editing and layout keep characters whole"` |
| `remove_prefix`/`remove_suffix` return the original on no match and match canonically | `conformance/run/string-methods.em` |
| A successful removal keeps the receiver's remaining original bytes | **none** |
| `words()` splits on `White_Space` runs and keeps no empty pieces; `split(" ")` keeps them | `conformance/run/string-text-tools.em`, `src/strings.zig: "words drops empty pieces between runs of whitespace"` |
| Character tests are false for `""`, ask every grapheme, `digit?` is ASCII only, `"A1".upper?()` true, `"1".upper?()` false | `conformance/run/string-text-tools.em`, `src/strings.zig: "character tests ask about every character, and need at least one"` |
| `collapse_repeats()` keeps the first of each run of canonically equal graphemes | `conformance/run/string-methods.em`, `src/strings.zig: "string editing and layout keep characters whole"` |
| `partition(separator)` returns before, match, after, or `(text, "", "")` without a match | `conformance/run/string-methods.em` |
| `partition` with an empty separator is an error | **none** |
| Padding measures graphemes; `fill` must be one grapheme; a negative width is an error; a wide string is unchanged | `conformance/run/string-methods.em`, `conformance/runtime-errors/string-padding.em`, `src/strings.zig: "string editing and layout keep characters whole"` |
| `"hi".pad_center(5, "-")` is `"-hi--"` | `conformance/run/string-methods.em` |
| Searching matches only at character boundaries and compares canonically: `"café".contains?("e")` is false | `src/emerald.zig: "the string vocabulary"`, `src/strings.zig: "searching never divides a character"` |
| `trim` removes whole characters of Unicode whitespace | `conformance/run/unicode-whitespace.em`, `src/strings.zig: "trim works in whole characters"` |
| `replace(old, new)` replaces every occurrence | `conformance/run/string-methods.em`, `src/strings.zig: "split, replace, and lines"` |
| `split("")` is an error pointing to `chars()` | `src/emerald.zig: "the string vocabulary"` |
| `replace` with an empty `old` is an error | **none** |
| `+` joins two strings, `+=` appends, and `"Score: " + 10` is an error suggesting `to_string()` or interpolation | `conformance/diagnostics/string-plus-number.em`, `conformance/run/string-methods.em` |
| `to_int` takes an optional sign and digits; `to_float` takes a fraction and exponent | `src/strings.zig: "parsing takes the whole string and reports what went wrong"`, `src/emerald.zig: "converting between strings and numbers"` |
| `to_float` accepts `Infinity`, `-Infinity`, and `NaN` | **none** |
| `to_string()` gives the display of an `Int`, `Float`, or `Bool` | `src/emerald.zig: "converting between strings and numbers"` |
| `code_points()` gives the stored scalars (a decomposed character has several); `bytes()` the exact UTF-8 bytes | `conformance/run/string-methods.em` |
| Equality is canonical and case-sensitive, and reaches dictionary keys and sets | `conformance/run/unicode-text.em`, `src/emerald.zig: "section 9.2's normalized equality reaches dictionary keys and sets"`, `src/unicode.zig: "canonically equivalent strings are equal and order the same way"` |
| Ordering compares normalized code points, locale-independent | `src/emerald.zig: "strings compare by canonical equivalence and order by code point"` |
| A `String` keeps exactly the bytes it was built from; `File.read` then writing back reproduces them | **none** |
| Equal strings hash equally (normalized hash) | `src/Value.zig: "a hash agrees with equality for strings, which normalize first"` |

## 9.3 Numeric vocabulary

| Rule | Covered by |
| --- | --- |
| `clamp`/`between?` are inclusive; reversed bounds are an error | `conformance/run/int-methods.em`, `conformance/run/int-method-errors.em`, `conformance/run/float-method-errors.em` |
| Signs do not change `digits`, `gcd`, `lcm`; `0.digits()` is `[0]`; `gcd(0, 0)` is `0`; `lcm` with zero is zero | `conformance/run/int-methods.em` |
| `multiple_of?` accepts negative divisors; a zero divisor is an error | `conformance/run/int-methods.em`, `conformance/run/int-method-errors.em` |
| `0.factorial()` is `1`; a negative factorial is an error | `conformance/run/int-methods.em`, `conformance/run/int-method-errors.em` |
| `abs`, `gcd`, `lcm`, `factorial` raise when the result does not fit `Int` | `conformance/runtime-errors/int-absolute-overflow.em`, `conformance/run/int-method-errors.em` |
| `to_character()` inverts `code_points()`; negative, past 1114111, or a surrogate raises with the reason | `conformance/run/string-text-tools.em`, `conformance/runtime-errors/to-character-negative.em`, `conformance/runtime-errors/to-character-past-end.em`, `conformance/runtime-errors/to-character-surrogate.em` |
| `round_to(places)`: positive, zero, and negative places; halves away from zero | `conformance/run/float-methods.em` |
| `round_to` with extreme place counts leaves the value or gives signed zero; NaN and infinity propagate | `conformance/run/float-methods.em` |
| `floor`, `ceil`, `round`, `truncate` return `Int`; `round` ties away from zero; `truncate` toward zero | `conformance/run/float-methods.em` |
| The five Float-to-Int operations reject NaN, infinity, and out-of-range results | `conformance/run/float-method-errors.em`, `conformance/runtime-errors/float-to-int.em` |
| Both signed zeros answer true to `zero?()` | `conformance/run/float-methods.em` |
| Both signed zeros answer false to `positive?()` and `negative?()` | **none** |
| NaN answers true only to `nan?()`; infinity is not finite and is `infinite?` | `conformance/run/float-methods.em` |
| Infinite interval bounds are valid; a NaN bound raises; a NaN receiver propagates through `clamp` and makes `between?` false | `conformance/run/float-methods.em`, `conformance/run/float-method-errors.em` |
| `square_root()` and `to_radians()` are Float receiver methods | `conformance/run/float-receiver-math.em` |
| `Math` constants and functions accept Int through widening and return Float | `conformance/run/math.em` |
| `Math` follows IEEE: out-of-domain inputs give NaN | `conformance/run/math.em` |
| `Math.natural_log(0)` gives `-Infinity` | **none** |
| `Math.max`/`min`: one ordered type, Int beside Float widens, equal values give `first`, optional or unordered is a checking error, exactly two arguments | `conformance/run/math-max-min.em`, `conformance/diagnostics/math-max-min.em` |
| `Math.max`/`min` raise on NaN | `conformance/runtime-errors/math-max-nan.em` |
| `Math` functions must be called, not kept as values | `conformance/diagnostics/math-functions-as-values.em`, `conformance/diagnostics/math-constants-called.em` |
| A project's own `Math` namespace takes the name | `conformance/run/emerald-builtins`, `conformance/diagnostics/math-project-shadow` |
| `random(range)` and `random_fraction()` in `[0.0, 1.0)` | `conformance/run/randomness.em`, `conformance/run/random-fraction.em` |
| Choosing from an empty range is an error | `conformance/runtime-errors/random-empty-range.em`, `conformance/runtime-errors/seeded-random-empty-range.em` |
| `List.random()` and `Random.choose` give `nothing` for an empty List | **none** |
| `shuffle()` returns a new list; `shuffle!()` changes a `var` list; both keep every element | `conformance/run/randomness.em`, `conformance/run/collection-mutation-copies.em` |
| Two generators with the same seed and operations give the same results | `conformance/run/randomness.em` |

## 9.4 Standard-library recovery audit

| Rule | Covered by |
| --- | --- |
| Parsing accepts surrounding whitespace and otherwise needs the whole string | `src/strings.zig: "parsing takes the whole string and reports what went wrong"` |
| Malformed or out-of-range input raises for the strict form, falls back for `_or`, gives `nothing` for `_maybe` | `src/emerald.zig: "converting between strings and numbers"`, `conformance/runtime-errors/not-a-number.em` |
| `Float.to_int()` truncates toward zero and raises for NaN, infinity, and out-of-range values | `conformance/run/float-methods.em`, `conformance/run/float-method-errors.em` |
| Float display: shortest round-trip, `2.0` keeps its marker, `-0.0`, scientific below `1e-6` or at least `1e16` with boundaries on either side, `Infinity`/`-Infinity`/`NaN` | `conformance/run/float-display.em`, `src/Value.zig: "scientific notation applies outside the fixed range, boundaries included"` |
| Historical spellings remain rejected: `has_key?` gets `contains_key?` | `conformance/lsp/quickfix-dict-method.em` |
| Historical spellings `read_line` (as a prelude function), `slice`, `pad_left`/`pad_right`, `intersect`, and `Kernel` are rejected with Emerald's name | **none** (the checker maps `slice`, but no case exercises it or the others) |

## 10.1 Value and reference semantics

| Rule | Covered by |
| --- | --- |
| Assigning or passing a struct copies; a class shares the object | `conformance/run/struct-fields.em`, `conformance/run/classes.em` |
| Struct `var` fields mutate with real copying | `conformance/run/struct-field-assignment.em`, `src/Heap.zig: "uniqueStruct copies a shared instance before it changes"` |
| Classes compare by identity; related static types may be compared; unrelated classes are a compile-time mismatch | `conformance/run/classes.em`, `conformance/diagnostics/class-mutability.em`, `conformance/diagnostics/inheritance-members.em` |
| Structs compare field by field | `conformance/run/struct-fields.em`, `conformance/run/equatable-and-hashable.em` |
| A class stored in a struct still compares by identity | **none** |
| A class declares the same kinds of members as a struct and follows the same construction rules | `conformance/run/classes.em`, `conformance/run/inheritance.em` |
| `const` stops at the first reference: a `const` field of an object, or a value held in one, still cannot change | `conformance/diagnostics/class-mutability.em` |
| A block or nested function in a class method may use `self` | `conformance/run/classes.em` (`on_resize`) |
| A struct in an object's field is taken while its changing method or setter runs; reaching it meanwhile is a runtime error | `conformance/runtime-errors/object-field-taken.em`, `conformance/run/class-nesting.em` |
| A class getter may change its object | **none** |
| A struct method that changes only an object the struct holds does not change the struct | **none** |
| An object displays field by field; one met again while displayed shows `Name(...)` | `conformance/run/class-nesting.em`, `conformance/run/inheritance.em` |

## 10.2 Fields and construction

| Rule | Covered by |
| --- | --- |
| A `const` struct field can be neither replaced nor changed (`self.position.x = 1` rejected) | `conformance/diagnostics/const-field-assignment-nested.em`, `conformance/diagnostics/const-field-list-mutation.em` |
| Nested assignment through a computed property is rejected | `conformance/diagnostics/property-changed-in-place.em` |
| Field defaults run in declaration order, once per construction | `conformance/run/struct-field-defaults.em` |
| A default may read earlier fields but not later ones, nor `self` whole, nor its methods or properties | `conformance/diagnostics/field-default-reads-later.em`, `conformance/diagnostics/field-default-uses-self.em` |
| The generated constructor takes one parameter per field in order; defaulted fields may be skipped by naming later ones | `conformance/run/struct-field-defaults.em`, `conformance/diagnostics/generated-constructor-named-fields.em` |
| Under a custom constructor defaults run first, and a default may read only earlier defaulted fields | `conformance/run/struct-field-defaults.em`, `conformance/diagnostics/field-default-custom-constructor.em` |
| An explicitly supplied argument replaces the default, which then does not run | `conformance/run/struct-field-defaults.em` |
| Every field must be definitely initialized before construction completes | `conformance/diagnostics/constructor-missing-field.em`, `conformance/diagnostics/constructor-branch-missing-field.em`, `conformance/diagnostics/constructor-read-before-set.em` |
| A `const` field is set exactly once, and never inside a loop | `conformance/diagnostics/constructor-const-set-twice.em`, `conformance/diagnostics/constructor-const-in-loop.em` |
| A custom constructor replaces the generated one; at most one constructor | `conformance/run/struct-constructor.em`, `conformance/diagnostics/duplicate-constructor.em` |
| A derived constructor calls `super(...)` first when the base needs arguments | `conformance/diagnostics/inheritance-construction.em` |
| A zero-argument base call is inserted when possible | `conformance/run/inheritance.em` |
| Base construction finishes before derived defaults and the rest of the derived constructor | `conformance/run/inheritance.em` |
| A bare constructor `return` only after every field is set; no replacement values | `conformance/diagnostics/constructor-early-return.em`, `conformance/diagnostics/constructor-returns-value.em`, `conformance/diagnostics/constructor-replaces-self.em` |
| A fieldless type gets a generated zero-argument constructor | `conformance/run/fieldless-structs.em` |
| A subclass without a constructor gets one only when the base and its fields need no arguments | `conformance/diagnostics/inheritance-construction.em` |
| Before all fields are ready, `self` may not escape and methods may not be called | `conformance/diagnostics/constructor-self-escape.em`, `conformance/diagnostics/method-before-ready.em`, `conformance/diagnostics/property-before-ready.em` |
| Overridable methods may not be called through `self` during construction | `conformance/diagnostics/inheritance-members.em` |

## 10.3 Properties

| Rule | Covered by |
| --- | --- |
| A read-only property uses `const` and a direct body; a writable one uses `var` with `get` and `set` | `conformance/run/struct-properties.em`, `conformance/diagnostics/property-const-with-blocks.em`, `conformance/diagnostics/property-missing-set.em` |
| A property runs on every read and is not cached | **none** (no case observes a second read recomputing) |
| The setter receives the proposed value through a read-only `value` | `conformance/run/struct-properties.em` (reading `value`); its being read-only: **none** |
| Compound assignment runs the getter once and the setter once | **none** (`run/struct-properties.em` does one but does not count the calls) |
| A getter may not change `self` | `conformance/diagnostics/property-getter-changes-self.em` |
| A setter changes `self` and owns the binding while it runs | `conformance/runtime-errors/setter-receiver-in-use.em`, `conformance/diagnostics/property-set-on-const.em` |
| A field, a property, and a method share one name space | `conformance/diagnostics/property-name-clash.em`, `conformance/diagnostics/writable-property-method-clash.em`, `conformance/diagnostics/duplicate-method.em` |
| A read-only property cannot be assigned | `conformance/diagnostics/property-read-only.em` |

## 10.4 Type-level members

| Rule | Covered by |
| --- | --- |
| A type-level member is declared with the type's name in front, inside its own braces, and the name must be that type | `conformance/run/type-level-members.em`, `conformance/diagnostics/type-member-wrong-type.em`, `conformance/diagnostics/type-function-outside-type.em` |
| Type-level fields may be `var` or `const` and need initial values | `conformance/diagnostics/type-field-needs-value.em`, `conformance/diagnostics/type-field-read-only.em` |
| Reached through the type, never through a value; an instance member never through the type | `conformance/diagnostics/type-member-through-value.em`, `conformance/diagnostics/instance-member-through-type.em` |
| A type-level function has no `self` | `conformance/diagnostics/type-member-self.em` |
| Type-level members share the type's one name space | `conformance/diagnostics/type-member-name-clash.em` |
| An unannotated type-level field holds its value's type | `conformance/diagnostics/type-field-type-mismatch.em` |
| A type-level field's value may read only earlier fields | `conformance/diagnostics/type-field-reads-later.em` |
| Setup runs once, in order, on first construction or member access | `conformance/run/type-level-members.em`, `conformance/run/type-level-members-project` |
| Reaching a field that setup has not reached, through a function, is an initialization-cycle error | `conformance/runtime-errors/type-setup-cycle.em` |
| A type-level field is not narrowed | **none** |
| Type-level computed properties are not part of the design | `conformance/diagnostics/type-field-needs-value.em` |

## 10.5 Privacy

| Rule | Covered by |
| --- | --- |
| A leading underscore makes any member private; the checker enforces it | `conformance/diagnostics/private-members.em`, `conformance/diagnostics/private-member-through-type.em` |
| Code inside the type's braces, including lambdas, defaults, and `other._count`, may reach it | `conformance/run/private-members.em` |
| Code outside the braces cannot, even in the same file | `conformance/diagnostics/private-members.em` |
| From outside, the generated constructor may not be given a private field; later fields are passed by name | `conformance/diagnostics/private-members.em`, `conformance/run/private-members.em` |
| A private field with no default means the type cannot be built outside | `conformance/diagnostics/private-members.em` |
| Equality and display still include private fields | `conformance/run/private-members.em` (display); equality: **none** |

## 10.6 One braced form

| Rule | Covered by |
| --- | --- |
| Classes, structs, traits, and enums always brace their bodies (a braceless body is an error) | `src/Parser.zig: "Allman brace style still leaves a genuinely missing body an error"` |

## 10.7 Inheritance and overriding

| Rule | Covered by |
| --- | --- |
| At most one base class; a struct cannot extend | `conformance/run/inheritance.em`, `conformance/diagnostics/struct-extends.em`, `conformance/diagnostics/inheritance-overrides.em` |
| An `@override` must match a real overridable member; a same-named member without it is a diagnostic | `conformance/diagnostics/inheritance-overrides.em` |
| A nonabstract subclass must implement every abstract member; an `@abstract` class cannot be constructed | `conformance/diagnostics/inheritance-construction.em` |
| Constructors are not inherited | `conformance/diagnostics/inheritance-construction.em` |
| A class shares one set of names with its bases, including fields, type-level, and private members | `conformance/diagnostics/inheritance-overrides.em` |
| An override takes the same parameters and gives the same type, a subclass, or a present value for an optional | `conformance/diagnostics/inheritance-overrides.em`, `conformance/run/inheritance.em` |
| An overriding property keeps `var`/`const` and its type | `conformance/diagnostics/inheritance-overrides.em` |
| A private member cannot be overridden, so a constructor may call a private method once fields are set | `conformance/diagnostics/inheritance-overrides.em`, `conformance/run/inheritance.em` |
| Type-level members are not inherited | `conformance/diagnostics/type-member-not-inherited.em` |
| `super.name` reaches the base method or property, including its setter | `conformance/run/inheritance.em` |
| `super` never reaches a field or an abstract method | `conformance/diagnostics/inheritance-members.em`, `conformance/diagnostics/inheritance-construction.em` |
| `super` is allowed only once every field is set | `conformance/diagnostics/inheritance-members.em` |
| `super(...)` may only be a constructor's first statement | `conformance/diagnostics/inheritance-construction.em`, `conformance/diagnostics/inheritance-syntax.em` |
| An object runs its own class's version however reached; a captured method is that version | `conformance/run/inheritance.em` |
| Running a version whose class's part has not begun is a runtime error | `conformance/runtime-errors/override-before-built.em`, `conformance/runtime-errors/operator-before-built.em` |
| Taking a method from such an object is allowed; the check is made at the call | `conformance/runtime-errors/captured-override-before-built.em`, `conformance/run/inheritance.em` |

## 11.1 Trait purpose

| Rule | Covered by |
| --- | --- |
| A bodyless signature is a requirement and a body a default; no `@abstract` in a trait | `conformance/run/traits.em`, `conformance/diagnostics/trait-syntax.em` |
| A `const` requirement is met by a public `const`/`var` field or readable property | `conformance/run/traits.em` |
| A `var` requirement needs a public writable field or get/set property; never the reverse | `conformance/diagnostics/traits.em`, `conformance/run/traits.em` |
| Private members cannot satisfy public requirements | **none** |
| Adopting without supplying a requirement is reported by name | `conformance/diagnostics/traits.em`, `conformance/diagnostics/trait-adoption-one-method.em`, `conformance/diagnostics/trait-adoption-partial-many.em` |

## 11.2 Composition and conflicts

| Rule | Covered by |
| --- | --- |
| Adoption is explicit: matching members do not establish conformance | `conformance/diagnostics/trait-not-adopted.em`, `conformance/diagnostics/trait-adoption-two-methods.em` |
| Trait membership is inherited; an `@abstract` class may defer requirements to subclasses | `conformance/run/traits.em` |
| Traits build on traits with `with`; a trait cannot build on itself | `conformance/diagnostics/traits.em`, `conformance/diagnostics/trait-syntax.em` |
| Structs adopt traits but do not inherit, and must satisfy requirements immediately | `conformance/diagnostics/traits.em`, `conformance/diagnostics/struct-extends.em` |
| A class's own implementation wins over a trait default | `conformance/run/traits.em`, `conformance/diagnostics/trait-adoption-default-override-applied.em` |
| Inherited class methods outrank trait defaults | **none** |
| Two traits supplying the same default need an explicit implementation; trait order never selects | `conformance/diagnostics/traits.em` |
| Compatible duplicate requirements need one implementation; a writable property requirement subsumes a read-only one | **none** |
| Different required types for one name conflict | `conformance/diagnostics/traits.em` |
| `TraitName.method(self, ...)` runs that trait's default | `conformance/run/traits.em`, `conformance/diagnostics/traits.em` |
| Private trait helpers stay private and do not conflict across traits or with a type's private member | `conformance/run/traits.em`, `conformance/diagnostics/traits.em` |
| Traits may provide computed-property defaults | `conformance/run/traits.em` |
| A method implementing or replacing a requirement uses `@override`; a property never does | `conformance/diagnostics/traits.em`, `conformance/diagnostics/trait-adoption-override-applied.em` |
| Implementations keep parameter names and cannot replace defaults; a requirement's defaults apply however it is reached | `conformance/diagnostics/traits.em`, `conformance/run/traits.em` |
| A trait-typed binding keeps the value's struct copy or class sharing | `conformance/run/traits.em` |
| Equality through a trait type is deferred (rejected) | `conformance/diagnostics/traits.em` |
| A change through a trait value needs a `var`; a struct requirement that changes the value changes the trait variable | `conformance/diagnostics/traits.em`, `conformance/run/traits.em` |
| A trait has no constructor, type-level members, `@abstract`, or stored values | `conformance/diagnostics/trait-syntax.em` |
| A conflict between traits is reported once, where they are first brought together | **none** |
| `Trait.method` cannot be taken as a value; `value.method` takes the value's own version | `conformance/diagnostics/traits.em`, `conformance/run/traits.em` |
| `Trait.method(value)` may run a changing default only on an object | **none** |
| `is` tests for a trait and narrows to it | `conformance/run/traits.em` |

## 11.3 Associated types and generics boundary

| Rule | Covered by |
| --- | --- |
| Types take parameters in brackets; a use writes them as a type, never at a call | `conformance/run/generics-grid.em`, `conformance/diagnostics/generics-type-at-call.em` |
| A parameter neither argument nor destination determines is an error asking for the type | `conformance/diagnostics/generics-cannot-tell.em`, `conformance/diagnostics/generics-function-cannot-tell.em` |
| Generic types are invariant | `conformance/diagnostics/generics-invariant.em` |
| A type in brackets cannot be optional | `conformance/diagnostics/generics-optional-argument.em`, `conformance/diagnostics/generics-optional-inferred.em`, `conformance/diagnostics/generics-function-optional.em` |
| An `Int` where `T` is `Float` widens | `conformance/run/generics-grid.em`, `conformance/run/generics-functions.em` |
| A bare `T` has no `==`, order, arithmetic, members, or key use | `conformance/diagnostics/generics-parameter-equality.em`, `conformance/diagnostics/generics-parameter-order.em`, `conformance/diagnostics/generics-parameter-member.em`, `conformance/diagnostics/generics-parameter-key.em` |
| A struct holding a `T` still compares by fields; a generic struct is a key when every field is | `conformance/run/generics-values.em` |
| Type-level members and nested types cannot use the type's parameters | `conformance/diagnostics/generics-type-member.em` |
| `is` cannot test a type with arguments | `conformance/diagnostics/generics-is-test.em` |
| `Json` does not encode a generic type | `conformance/diagnostics/generics-json-encode.em` |
| `Csv` does not encode or decode a generic type | **none** |
| Functions and methods take their own type parameters, worked out from destination, arguments, then block result | `conformance/run/generics-functions.em`, `conformance/run/generics-methods.em` |
| A generic function taken as a value needs a function type | `conformance/diagnostics/generics-function-capture.em`, `conformance/run/generics-functions.em` |
| A constructor takes no type parameters of its own | `conformance/diagnostics/generics-constructor.em` |
| `[T with Trait]`: each type given must adopt it, and inside, values have the trait's members | `conformance/run/generics-constraints.em`, `conformance/diagnostics/generics-constraint-unsatisfied.em`, `conformance/diagnostics/generics-constraint-not-trait.em` |
| `==` needs `Equatable`, ordering needs `Ordered`, keys need `Hashable` | `conformance/diagnostics/generics-constraint-equality-needs-equatable.em`, `conformance/diagnostics/generics-constraint-order-needs-ordered.em`, `conformance/diagnostics/generics-constraint-annotation.em` |
| `Int`, `Float`, `String` adopt all four prelude traits; `Bool` all but `Ordered` | `conformance/run/generics-constraints.em`, `conformance/diagnostics/generics-constraint-scalar.em`, `conformance/diagnostics/generics-bool-compare.em` |
| `Bytes` counts as `Equatable` and `Hashable` | **none** |
| Only one trait per parameter | `conformance/diagnostics/generics-constraint-two-traits.em` |
| Generic enums; a choice without data fits any type | `conformance/run/generics-enums.em`, `conformance/diagnostics/generics-enum-untold.em` |
| A generic class cannot extend or be extended; traits, trait methods, overrides, `@operator` methods, and tests take no type parameters | `conformance/diagnostics/generics-extends.em`, `conformance/diagnostics/generics-generic-subclass.em`, `conformance/diagnostics/generics-reserved-trait.em`, `conformance/diagnostics/generics-trait-method.em`, `conformance/diagnostics/generics-override.em`, `conformance/diagnostics/generics-operator.em`, `conformance/diagnostics/generics-test-function.em` |
| A generic value's `type_name` is its declaration's bare name | **none** |

## 11.4 `Self`

| Rule | Covered by |
| --- | --- |
| `Self` is written only in method and type-level function parameter and result types | `conformance/diagnostics/self-type.em` |
| In a trait, `Self` is the adopting type; inside defaults `self` is a `Self` | `conformance/run/operators.em` |
| On a class, a trait's `Self` is the first class to adopt it; an abstract adopter's subclasses take the abstract class | `conformance/run/operators.em`, `conformance/diagnostics/self-type.em` |
| Through a trait-typed value, a member taking `Self` cannot be called | `conformance/diagnostics/self-type.em` |
| `Trait.method(value)` cannot run a default whose signature mentions `Self` | `conformance/diagnostics/self-type.em` |

## 11.5 Operator overloading

| Rule | Covered by |
| --- | --- |
| `a + b` runs `a.add(b)`; `a < b` runs `compare` | `conformance/run/operators.em`, `conformance/run/operator-annotations-slice-one.em` |
| `@operator` takes one of `+ - * /`; other symbols are rejected | `conformance/diagnostics/operator-annotation-syntax.em` |
| `@operator` belongs on a public instance method | `conformance/diagnostics/operator-annotation-placement.em` (a top-level function); private or type-level methods: **none** |
| The method takes one required parameter and has an explicit result type | **none** |
| Several registrations for one symbol need disjoint parameter types; Int/Float and class/subclass overlap | `conformance/diagnostics/operator-annotation-overlap.em`, `conformance/run/operator-annotations-selection.em` |
| Selection uses the left operand's static type, then virtual dispatch | `conformance/run/operator-annotations-selection.em` |
| An `@override` inherits its base registration and never repeats `@operator` | **none** |
| `a op= b` uses the selected operation, evaluates the destination once, and must be assignable back | `conformance/diagnostics/operator-annotation-compound-result.em` |
| Same-type `Self -> Self` operations must use `add`/`subtract`/`multiply`/`divide`; those names are reserved for that shape | `conformance/diagnostics/operator-annotation-canonical-names.em` |
| There is no reversal: `Int * Money` stays invalid | `conformance/diagnostics/operators.em` |
| `%`, `//`, `**`, and unary `-` are not overloadable | `conformance/diagnostics/operators.em` (`%`); `//`, `**`, unary `-`: **none** |
| The left operand may not be optional | **none** |
| Every ordering comparison in a chain runs `compare` | `conformance/run/operators.em` |
| An operator never changes a struct operand, so a changing method cannot back one | `conformance/diagnostics/operators.em`, `conformance/run/operators.em` |
| An operator on `self` during construction follows 10.2's rules | `conformance/diagnostics/operators.em`, `conformance/runtime-errors/operator-before-built.em` |
| Arithmetic authorization comes from `@operator`, not a prelude trait | `conformance/diagnostics/operator-trait-removed.em` |

## 12. Enums and branching

| Rule | Covered by |
| --- | --- |
| Enum values have the enum's type, compare with `==`, display as `Direction.north` | `conformance/run/enums.em` |
| Declaration order gives no ordering; `<` needs `Ordered` | `conformance/diagnostics/enums.em`, `conformance/run/enums.em` |
| Enums may have methods, computed properties, and traits, but no stored fields | `conformance/run/enums.em`, `conformance/diagnostics/enum-syntax.em` |
| A nonexhaustive enum statement case warns; an empty `else` acknowledges | `conformance/diagnostics/enum-data-match-check.em`, `conformance/run/warning-does-not-block-execution.em`; empty `else`: **none** |
| Values come first, at least one; a value after a member, a stored field, a constructor, or `extends` is an error | `conformance/diagnostics/enum-syntax.em` |
| Values are `const` type-level members, always written with the enum's name, sharing its names | `conformance/diagnostics/enum-names.em`, `conformance/diagnostics/enums.em` |
| An enum is never constructed, extended, or adopted | `conformance/diagnostics/enums.em` |
| An enum is a dictionary key | `conformance/run/enums.em` |
| A choice carries named, typed, required data, built by a positional or named call; arguments run once in written order | `conformance/run/enum-data.em`, `conformance/diagnostics/enum-data.em` |
| A choice with data is not a value without a call; a choice without data is never called | `conformance/diagnostics/enum-data.em` |
| Data items have no defaults and are read-only values | `conformance/diagnostics/enum-data-syntax.em`, `conformance/run/enum-data.em` |
| Equality compares enum, choice, then data; display shows labelled data | `conformance/run/enum-data.em` |
| An enum with data is a key only when all data is; a recursive enum is not | `conformance/diagnostics/enum-data-keys.em`, `conformance/run/enum-data.em` |
| JSON, CSV, and `Console.table` refuse an enum carrying data | `conformance/diagnostics/enum-data.em` (JSON encode and decode, table); CSV: **none** |
| `when Choice(name)` selects every value of the choice, whatever custom equality says, naming data in declaration order | `conformance/run/enum-data.em` |
| `_` ignores a position; a name that is another position's label is an error | `conformance/run/enum-data.em`, `conformance/diagnostics/enum-data-match.em` |
| No values, named arguments, nested patterns, or guards in a match | `conformance/diagnostics/enum-data-match.em` |
| A choice match needs its own arm, covers its choice, and a second match of it is an error | `conformance/diagnostics/enum-data-match.em`, `conformance/diagnostics/enum-data-match-check.em` |
| A data choice written without names in `when` is an error showing the match | `conformance/diagnostics/enum-data-match-check.em` |
| Other alternatives compare by `==`; an optional subject still needs `when nothing` or `else` | `conformance/run/enum-data.em` |

## 13.1 Error model

| Rule | Covered by |
| --- | --- |
| Errors are classes rooted in `Error`; programs define subclasses and `raise` them | `conformance/run/errors.em` |
| Only an `Error` can be raised | `conformance/diagnostics/error-checking.em` |
| A subclass whose only state is the inherited message gets `Error(message)` construction | `conformance/run/errors.em` |
| A subclass adding fields declares constructors that begin with `super(...)` | `conformance/diagnostics/error-checking.em` (`MissingConstructor`) |
| Interpreter failures are `RuntimeError`, a failed assertion `AssertionError`, both catchable | `conformance/run/errors.em` |

## 13.2 Handling

| Rule | Covered by |
| --- | --- |
| `finally` runs whether the body returns, raises, or completes; `try` may have only `finally` | `conformance/run/errors.em` |
| Typed catches are tried top to bottom, first match only; an untyped catch takes any `Error` | `conformance/run/errors.em`, `conformance/diagnostics/error-checking.em` (a catch after one that handles everything) |
| A catch type must be an `Error` | `conformance/diagnostics/error-checking.em` |
| Bare `raise` in a catch re-raises the same value; elsewhere it is invalid | `conformance/run/errors.em`, `conformance/diagnostics/error-checking.em` |
| A re-raised error keeps its original failure location | **none** |
| `return`, `break`, or `continue` leaving a `finally` is forbidden; a loop wholly inside keeps loop control | `conformance/diagnostics/error-checking.em`, `conformance/run/errors.em` |
| A cleanup that raises while another error propagates reports both | `conformance/runtime-errors/finally-error.em` |
| Unhandled errors give an Emerald stack trace with file, line, function, and message, innermost first | `conformance/runtime-errors/error-in-function.em`, `src/emerald.zig: "a runtime error inside a function carries its stack trace"`, `src/emerald.zig: "a runtime error names the file each frame is in"` |

## 13.3 Resources

| Rule | Covered by |
| --- | --- |
| `FileHandle.read()` returns the rest; `read_line()` gives one line or `nothing` at the end | `conformance/run/file-streaming.em`, `src/emerald.zig: "FileHandle streams text, rejects invalid UTF-8, and rejects reads after close"` |
| `with_open` and `with_writer` close after completion, return, or error | `conformance/run/file-streaming.em`, `conformance/run/file-writer-streaming.em`, `src/emerald.zig: "FileWriter streams text, closes idempotently, and with_writer closes on every exit"` |

## 14.1 Projects and entry points

| Rule | Covered by |
| --- | --- |
| A file outside a project runs alone; two exercises declaring `helper` do not collide | **none** (no CLI-level case) |
| Inside a project every `.em` under the root is included without imports | `conformance/run/project`, `src/emerald.zig: "files in one directory see each other without qualification"` |
| `emerald run path/to/file.em` may select another entry | **none** |
| The project root is the directory holding `main.em`, independent of the working directory | **none** (`src/Project.zig: "a lone file outside the working directory is not placed in its project"` is related but does not test this) |
| Only the file's own directory is consulted; a subdirectory file run alone sees none of its project and names the entry to run | **none** |
| Only the entry file runs top-level statements; another file's are an error | `conformance/diagnostics/module-statement`, `src/emerald.zig: "section 14.1 gives only the entry file a top level that runs"` |
| A module file initializes once, on first member access, in declaration order; `using` does not initialize it | `conformance/run/module-initialization`, `src/emerald.zig: "section 14.1 initializes a module file once, on first use"` |
| Reaching a function of an initializing file is fine; reaching an unset binding is an initialization-cycle error | `conformance/runtime-errors/initialization-cycle`, `src/emerald.zig: "section 14.1 reports a cycle that reaches an unfinished binding"` |
| A failed initialization reports the original failure on later access without retrying | `conformance/run/caught-setup-errors` |
| A module-level binding outside the entry file needs a value where declared | `conformance/diagnostics/module-needs-value` |
| Type-level fields initialize lazily; mentioning the type in an annotation or `using` does not | `conformance/run/type-level-members.em` (annotation); through `using`: **none** |
| `Program.arguments` holds only the program's arguments, after `--` | `conformance/run/program-arguments.em`, `src/emerald.zig: "section 14.1's Program.arguments carries the program's own CLI arguments"` |
| `Program.environment(name)` gives `String?`, `nothing` when unset, empty name, or one holding `=`; non-UTF-8 raises `EncodingError` | `conformance/run/program-environment.em`, `src/emerald.zig: "section 15.10's Program.environment reads a set variable and refuses one that is not UTF-8"` |
| `Program.environment` cannot set, remove, or list variables | `conformance/diagnostics/program-environment.em` |
| A bare top-level `return` ends the program successfully after pending `finally` blocks; it cannot return a value | `conformance/run/top-level-return.em`, `conformance/diagnostics/top-level-return.em` |
| A top-level `return` is allowed only in the selected entry file | **none** |
| Statements after `exit()` are unreachable (warning) | **none** |

## 14.2 Namespaces and `using`

| Rule | Covered by |
| --- | --- |
| Another directory is reached through its path-derived namespace; `ui_kit/` is `UiKit` | `conformance/run/namespaces`, `src/Project.zig: "a directory name becomes a namespace segment"` |
| The file contributes nothing to the name | `conformance/run/project` |
| A directory that cannot be a name is reported, not skipped | `conformance/diagnostics/project-bad-directory`, `conformance/diagnostics/project-lone-bad-directory` |
| A module-level declaration named like a namespace is an error at the declaration | `conformance/diagnostics/namespace-clash` |
| A project name or top-level directory wins over a built-in, which stays reachable qualified | `conformance/run/emerald-namespace.em`, `conformance/run/emerald-builtins`, `conformance/run/math-project-shadow` |
| Hiding a language built-in warns with the qualified form; a standard-library name is silent; locals are exempt | `conformance/diagnostics/builtin-shadowing`, `conformance/diagnostics/print-error-shadowing.em`, `conformance/diagnostics/random-fraction.em` |
| A use of a library-only member on the program's own type explains the hiding | `conformance/diagnostics/library-shadowing.em`, `conformance/diagnostics/library-shadowing-value.em` |
| `Emerald` is reserved at the root and as a top-level directory | `conformance/diagnostics/emerald-reserved.em`, `conformance/diagnostics/project-reserved-directory` |
| `using Emerald` is a redundancy warning | `conformance/diagnostics/using-emerald-redundant.em` |
| Diagnostics name built-in types bare | **none** (implied by many cases, but none checks a hidden built-in's name in a type mismatch) |
| `using` imports direct public names; aliases name a namespace, a declaration, or a nested type | ``src/emerald.zig: "`using` makes a namespace's names directly visible"``, ``src/emerald.zig: "`using` can alias a namespace or one name in it"``, `conformance/run/namespaces` |
| `using` applies to the whole file wherever it appears | **none** |
| `using` is file-local | **none** |
| An ambiguous short name is reported when used | `conformance/diagnostics/ambiguous-using` |
| A name the file's own namespace declares is never ambiguous | `src/emerald.zig: "a local shadows a name its namespace declares"` |
| A name from another directory needs its namespace or `using` | `conformance/diagnostics/name-needs-its-namespace` |
| A leading underscore makes a module-level declaration private to its file | `conformance/diagnostics/private-across-files`, `src/emerald.zig: "section 14.2 keeps a leading underscore private to its own file"` |
| Two files in one directory declaring the same public name is an error naming the first | `conformance/diagnostics/duplicate-in-namespace`, `src/emerald.zig: "two files in one directory cannot declare the same public name"` |
| `using` an unknown namespace is an error | `conformance/diagnostics/using-unknown` |

## 14.3 File shapes

| Rule | Covered by |
| --- | --- |
| A struct, class, or enum may nest struct, class, enum, and trait types; a trait may not | `conformance/run/nested-types`, `conformance/diagnostics/nested-type-refusals.em` |
| An enum's nested types come after its values | **none** |
| A nested type shares its enclosing type's member name space | `conformance/diagnostics/nested-type-clashes.em` |
| A nested type is always reached through its enclosing type, even from inside | `conformance/diagnostics/bare-nested-type.em`, `conformance/diagnostics/nested-type-paths.em` |
| A directory namespace comes first in a path; an alias may name a nested type | `conformance/run/nested-types` |
| A nested type displays with enclosing types but without its directory namespace | `conformance/run/nested-types` |
| Privacy follows the braces rule in both directions; a private nested type is reachable only inside its encloser | `conformance/diagnostics/nested-type-privacy.em` |
| `Self` in a nested type's method means the nested type | **none** |
| A nested type is not inherited | `conformance/diagnostics/nested-type-paths.em`, `conformance/diagnostics/nested-type-refusals.em` |
| Reaching a nested type's type-level member sets up the nested type, not its encloser | **none** |
| A nested type's bodies are checked as a top-level type's are | `conformance/diagnostics/nested-type-body.em` |

## 14.4 Packages and foreign code

| Rule | Covered by |
| --- | --- |
| A library copied to the root works unchanged when it names itself | `conformance/run/copied-library` |
| A `main.em` inside a library is an error ("this would never run") | `src/emerald.zig: "section 14.1 gives only the entry file a top level that runs"` |

## 15.1 Philosophy

| Rule | Covered by |
| --- | --- |
| Every built-in is reachable qualified through `Emerald` (`Emerald.print`, `Emerald.File`, `Emerald.Math.pi`) | `conformance/run/emerald-namespace.em`, `conformance/run/emerald-builtins` |
| `Textual.to_string()` controls display in `print`, `write`, and interpolation | `conformance/run/textual.em` |
| A `to_string` without adopting `Textual` changes nothing and warns | `conformance/diagnostics/textual-without-adoption.em` |
| Enums without `Textual` display their qualified names | `conformance/run/textual.em`, `conformance/run/enums.em` |
| An adopting value renders through `to_string` nested anywhere, unquoted | `conformance/run/textual.em` |
| A raising `to_string` propagates from `print`/interpolation, catchable, with no partial line | `conformance/run/textual.em` |
| A self-reaching value shows `Name(...)` at the repeat | `conformance/run/textual.em` |
| Assertion failures and runtime error text keep the field-based form | **none** |

## 15.2 Prelude

| Rule | Covered by |
| --- | --- |
| A program's own `Ordered` takes the name in the files that see it | `conformance/diagnostics/operators-shadowed-trait.em` |
| `input(prompt)` writes the prompt, reads a line, and removes its line ending | `conformance/run/first-program.em`, `src/emerald.zig: "the first program: input and interpolation"` |
| `input` keeps other whitespace, and Enter alone returns `""` | **none** |
| End of input raises `InputError`; `input_maybe` gives `nothing` | `conformance/runtime-errors/input-ended.em`, `conformance/run/input-error.em`, `conformance/run/read-until-end.em`, `src/emerald.zig: "section 15.2: input_maybe reports the end of the input as absence"` |
| A line that is not valid UTF-8 raises | **none** |
| `print`/`write` take zero or more values, left to right, separated by one space; `write` adds no newline | `conformance/run/print-arguments.em`, `src/emerald.zig: "print takes zero or more values separated by one space"` |
| A string inside a collection displays quoted with escapes | `src/emerald.zig: "interpolation displays any value, and strings inside lists are quoted"` |
| `print_error` is `print` on standard error, after flushing standard output | `conformance/run/print-error.em`, `src/emerald.zig: "section 15.2's print_error writes to its own stream, after what print already wrote"` |
| When standard output is styled and standard error is not, `print_error` strips the styling | **none** |
| `exit()` succeeds; `exit(code)` takes 0 through 255; other statuses are diagnosed | `conformance/run/exit.em`, `conformance/runtime-errors/exit-status.em`, `conformance/diagnostics/exit.em` |
| `exit` unwinds pending `finally` blocks but is not caught as an error | `conformance/run/exit.em`, `src/emerald.zig: "section 15.2 exit reports its requested status after finally"` |
| An uncaught error exits with a nonzero status | `build.zig: reports_runtime` (status 2) |

## 15.3 Files, directories, and paths

| Rule | Covered by |
| --- | --- |
| Whole-file `read`, `write`, `append`, `read_lines`, `write_lines`, `copy`, `move`, `exists?` | `conformance/run/file-directory-path.em` |
| `File.exists?` and `Directory.exists?` are mutually exclusive for real paths | **none** (no case asks `File.exists?` of a directory or the reverse) |
| `Directory.create` makes parents and succeeds when the directory exists | `conformance/run/file-directory-path.em` |
| `Directory.delete` removes only empty directories | `conformance/runtime-errors/directory-not-empty` |
| `Directory.delete_recursive` is idempotent | `conformance/run/file-directory-path.em`, `src/emerald.zig: "Directory.delete_recursive removes a populated tree and is idempotent on an already-gone path"` |
| `Directory.list` returns full paths of files and subdirectories together | `conformance/run/file-directory-path.em` (count only; full paths: **none**) |
| `Path.join` takes a `List[String]`; `extension` omits its dot; `parent` gives `""` when there is none | `conformance/run/path.em` |
| `Path.absolute` is the only Path operation that touches the filesystem | `conformance/run/path.em` |
| `File.open` gives a read-only handle; `read_line()` gives `String?`; `close()` is idempotent | `conformance/run/file-streaming.em`, `src/emerald.zig: "FileHandle streams text, rejects invalid UTF-8, and rejects reads after close"` |
| `File.create` truncates or creates and gives a `FileWriter`; `close()` is idempotent | `conformance/run/file-writer-streaming.em`, `src/emerald.zig: "FileWriter streams text, closes idempotently, and with_writer closes on every exit"` |
| `read_line()` follows `read_lines`: a trailing newline adds no line; an unterminated last line is returned | `conformance/run/file-empty-lines.em`, `conformance/run/file-crlf-lines.em` |
| `write_lines` writes a newline after every line | **none** (no case reads the written bytes back with `read`) |
| Text operations are UTF-8 only; invalid UTF-8 raises `FileError` | `src/emerald.zig: "File read methods reject invalid UTF-8 as FileError"` |
| `write`, `write_binary`, `write_lines`, `append`, `create` create a missing file but no missing directory | `conformance/run/file-append-creates.em` (`append`); the other four: **none** |
| Other operations raise `FileError` for missing paths and access failures | `conformance/runtime-errors/file-missing.em`, `conformance/runtime-errors/file-read-directory.em`, `conformance/runtime-errors/file-write-directory.em`, `conformance/run/file-error-catch.em` |
| Reading a closed handle, or writing a closed writer, raises `FileError` | `conformance/runtime-errors/file-streaming-closed.em`, `conformance/runtime-errors/file-writer-streaming-closed.em` |
| `Bytes.from_list` takes 0 through 255 | `conformance/runtime-errors/bytes-from-list-range.em` |
| `String.to_bytes()`, `Bytes.to_string()`/`to_string_maybe()` convert only valid UTF-8 | `conformance/run/bytes-hex.em`, `conformance/run/bytes-binary-file.em` |
| `Bytes` has `count`, indexing, slicing, equality, concatenation, and key use | `conformance/run/bytes-binary-file.em`, `conformance/run/bytes-hex.em` |
| `read_bytes(count): Bytes?`, `read_all_bytes()`, `write_bytes(bytes)` | `conformance/run/bytes-binary-file.em` |

## 15.4 Regular expressions

| Rule | Covered by |
| --- | --- |
| `matches?` tests the whole text; `contains_match?`, `find`, `find_all` | `conformance/run/regex-basics.em` |
| Matching takes time linear in the text | `src/Regex.zig: "matching takes time in proportion to the text"` |
| Backreferences, lookaround, atomic groups, possessive repetition are refused by name | `src/Regex.zig: "refused patterns say what and where"` |
| Leftmost-first: greedy unless `?`, first alternative wins | `conformance/run/regex-basics.em`, `src/Regex.zig: "alternation and repetition prefer the first and the most"` |
| `.` and sets match whole graphemes; literals compare canonically; `[a-z]` never matches `é` | `conformance/run/regex-graphemes.em`, `src/Regex.zig: "a character is a grapheme"` |
| `\d` is ASCII; `\w` is UTS #18; `ignore_case` uses simple case folding | `conformance/run/regex-graphemes.em`, `src/Regex.zig: "ignoring case"`, `src/unicode.zig: "word characters are UTS #18's, across scripts"` |
| Counts up to 1000; options are named arguments, never inline flags | `src/Regex.zig: "refused patterns say what and where"` |
| `$` matches only at the end, or a line's end with `multiline` | `conformance/run/regex-basics.em`, `conformance/run/regex-graphemes.em`, `src/Regex.zig: "anchors and word boundaries"` |
| A repeated group never takes an empty round; `\B` matches an empty text | **none** |
| Matches never overlap; after an empty match the search moves one grapheme | `conformance/run/regex-basics.em`, `src/Regex.zig: "a matcher runs again from where the last match ended"` |
| `split` keeps empty pieces, but an empty match at the very start or end splits nothing off | `conformance/run/regex-replace-split.em` |
| Replacement text is literal; `replace_each` computes replacements | `conformance/run/regex-replace-split.em`, `conformance/run/regex-groups.em` |
| `RegexError` extends `RuntimeError`; a bad pattern's message quotes it, gives the grapheme position, and advises | `conformance/run/regex-errors.em`, `conformance/runtime-errors/regex-invalid-pattern.em` |
| A literal pattern is checked before the program runs, at the character inside the literal | `conformance/diagnostics/regex-literal-pattern.em` |
| `group`/`named` raise for a non-participating group; `_maybe` forms give `nothing`; a missing group raises from every form | `conformance/run/regex-groups.em`, `conformance/runtime-errors/regex-missing-group.em` |
| A `Regex` prints as its pattern, compares by pattern and options, and is a key | `conformance/run/regex-basics.em` |
| A `Regex.Match` prints as `Regex.Match("42" at 3..<5)` and cannot be built | `conformance/run/regex-basics.em`, `conformance/diagnostics/regex-match-not-built.em` |
| `Regex.escape(text)` matches the text exactly | `conformance/run/regex-basics.em` |

## 15.5 Formatting

| Rule | Covered by |
| --- | --- |
| `Int.to_string(base:)` with a named, defaulted base; invalid bases raise | `conformance/run/int-methods.em`, `conformance/run/int-method-errors.em` |
| `format(decimal_places:, group_digits:)` on Int and Float returns a String | `conformance/run/int-methods.em`, `conformance/run/float-methods.em`, `conformance/run/float-method-errors.em` |
| Infinity and NaN render plainly, ignoring `format`'s arguments, and are type-level Float constants | `conformance/run/float-methods.em`, `conformance/diagnostics/float-constant-call.em`, `conformance/diagnostics/float-type-member.em` |

## 15.6 Platform libraries: Console

| Rule | Covered by |
| --- | --- |
| A styled value is a `String` with SGR escapes, which count toward `count` and search | `conformance/color/console-style.em` |
| Color policy precedence: `--color`, then `NO_COLOR`, `FORCE_COLOR`, `TERM=dumb`, then the TTY | `src/ColorPolicy.zig` (13 tests, e.g. `"NO_COLOR wins over FORCE_COLOR when both are set"`) |
| Ordinary (non-TTY) execution defaults to no styling | `conformance/run/console-style-off.em` |
| Nested spans close and reopen the outer layer; a reset inside input reopens every layer | `conformance/color/console-style.em` |
| `Console.plain` removes only complete SGR sequences | `conformance/color/console-style.em` |
| `Console.clear()` emits `ESC[2J ESC[H` only on a terminal and nothing on a file or pipe | `conformance/run/console-clear.em`, `src/emerald.zig: "section 15.6's Console.clear clears a terminal and leaves other output alone"` |
| `--color` and `NO_COLOR` do not affect `clear`; `TERM=dumb` does | **none** |
| Tables, panels, and prompts return strings; prompts raise `InputError` at end of input | `conformance/color/console-layout.em`, `conformance/run/console-struct-table.em`, `conformance/run/console-prompts.em`, `conformance/runtime-errors/console-ask-ended.em` |

## 15.8 Dates and times

| Rule | Covered by |
| --- | --- |
| `Date.add(months:)` keeps the day or uses the month's last day; weeks and days count calendar days | `conformance/run/date-basics.em` |
| `days_until`, `months_until`, `years_until` count whole units toward zero (an age) | `conformance/run/date-basics.em` |
| Every `Duration` and `add`/`subtract` argument is named; `Duration(5)` is a check-time error listing units | `conformance/diagnostics/time-units-named.em` |
| `Date` fields, `weekday`, `month_name`, `day_of_year`, `days_in_month`, `leap_year?()`; `Weekday` displays as `Monday` | `conformance/run/date-basics.em` |
| `Weekday` does not adopt `Ordered` | **none** |
| Dates run from year 1 through 9999; a result outside raises | `conformance/run/date-basics.em`, `conformance/run/date-errors.em` |
| `Time(14, 30)` zeroes the rest; `add`/`subtract` wrap around midnight | `conformance/run/time-basics.em` |
| `DateTime.add` moves the date, then carries time units past midnight (`2026-03-01T01:00:00`) | `conformance/run/date-time-basics.em` |
| `duration_until` treats every day as 24 hours | `conformance/run/date-time-basics.em` |
| `Instant` arithmetic with `Duration`, `-` between two, Unix conversions rounding toward the past | `conformance/run/instant-basics.em` |
| `Instant(...)` and `Stopwatch()` diagnostics name the type-level function | `conformance/diagnostics/program-sleep.em` |
| A fixed zone is named like its offset, its minutes take the hours' sign, at most 18 hours | `conformance/run/instant-basics.em`, `conformance/run/date-errors.em` |
| Zones are equal by name: `TimeZone.fixed(hours: 0)` is not `TimeZone.utc` | `conformance/run/instant-basics.em` |
| `Stopwatch` uses the monotonic clock; `elapsed()` re-reads; `restart()` starts over | `conformance/run/clock.em` |
| `Program.sleep` takes only a `Duration`; a negative one raises | `conformance/diagnostics/program-sleep.em`, `conformance/run/date-errors.em` |
| `Duration` arithmetic: `/` by Int rounds toward zero, `/` by Duration gives Float; totals, wholes, `abs`, `zero?`, `negative?` | `conformance/run/duration-basics.em` |
| ISO display and `parse` that ignores surrounding whitespace; optional seconds; fractions in groups of three; `T` or space | `conformance/run/date-basics.em`, `conformance/run/time-basics.em`, `conformance/run/date-time-basics.em` |
| `parse_maybe` gives `nothing` instead of raising | `conformance/run/date-basics.em`, `conformance/run/time-basics.em` |
| `Duration` displays nonzero units largest first (`2d 3h`, `0s`, `-5m`) | `conformance/run/duration-basics.em` |
| `DateTimeError` names the wrong part and its range | `conformance/run/date-errors.em` |
| A prelude failure is reported at the program's call, without prelude frames | `conformance/runtime-errors/date-invalid-day.em` |
| Zone-taking functions default to `TimeZone.local` | `conformance/local-zone/clock-changes.em` |
| `TimeZone.local` is UTC by default for `check`, tests, and embedded runs | **none** |
| `run`/`test`/`repl` resolve `TZ` (empty is UTC, name, POSIX rule, path), then `/etc/localtime`; unreadable means UTC | `src/TimeZone.zig: "where the machine's zone comes from"`, `src/TimeZone.zig: "POSIX rule forms"` |
| A repeated wall time resolves to the earlier moment; a skipped one moves forward by the gap | `conformance/local-zone/clock-changes.em`, `conformance/run/named-zones.em` |
| `add(days: 1)` keeps the clock time; `Instant + Duration(days: 1)` keeps the length | `conformance/local-zone/clock-changes.em` |
| Named IANA zones with full history, from the built-in database | `conformance/run/named-zones.em`, `src/TimeZone.zig: "the built-in database"` |
| Zone names are case-sensitive; a wrong case is refused with the right spelling | `conformance/run/named-zones.em` |
| `TimeZone.named_maybe` gives `nothing` for an unknown name | `conformance/run/named-zones.em` |
| `US/Eastern` is not equal to `America/New_York` | `conformance/run/named-zones.em` |
| On Windows the local key name maps through CLDR | `src/TimeZone.zig: "Windows's description of a zone"` |

## 15.9 JSON

| Rule | Covered by |
| --- | --- |
| `Json.parse` gives the six kinds; `parse_maybe` gives `nothing` | `conformance/run/json-basics.em` |
| Navigation and conversions with `_maybe` forms | `conformance/run/json-basics.em`, `conformance/run/json-errors.em` |
| `int()` reads any whole JSON number that fits (`3`, `3.0`, `3e2`) | `conformance/run/json-basics.em` |
| A whole number at or past 2^63 is not an Int | `src/Json.zig: "a whole number at or past 2^63 is not an Int"` |
| A `Json` displays compactly and compares by JSON value; path does not affect equality | `conformance/run/json-basics.em` |
| Builders; `from_float` keeps `3.0` and `-0.0` and refuses NaN and infinity | `conformance/run/json-building.em`, `conformance/run/json-non-finite.em` |
| `Json.encode` compact by default, two-space indent with `pretty: true` | `conformance/run/json-building.em`, `conformance/run/json-encoding.em` |
| Encode accepts scalars, optionals (as null), List, `Dict[String, _]`, data-free enums, date/time values, and plain structs, in declaration and insertion order | `conformance/run/json-encoding.em`, `src/emerald.zig: "Json.encode writes ordinary checked values and rejects values JSON cannot represent"` |
| Encode accepts a struct that holds itself (a tree) | **none** |
| A private field is never written | **none** |
| A `Set` or non-string-keyed dictionary is a checking error | `conformance/diagnostics/json-encode-set.em`, `conformance/diagnostics/json-encode-dictionary-key.em`, `conformance/diagnostics/json-encode-struct-field.em` |
| A class, function, or byte data is a checking error | **none** |
| A non-finite Float is a runtime `JsonError` | `src/emerald.zig: "Json.encode writes ordinary checked values and rejects values JSON cannot represent"` |
| `Json.decode(text, as: Type)` builds the matching type family; other targets are checking errors | `conformance/run/json-decoding.em`, `conformance/diagnostics/json-decode-set.em` |
| `as:` is a type only in a call written `Json.decode`; elsewhere it is an ordinary argument | `conformance/run/as-argument.em` |
| Neither function can be taken as a value | `conformance/diagnostics/json-encode-decode-as-values.em` |
| Decoded structs must use their generated constructor | `conformance/diagnostics/json-decode-own-constructor.em` |
| A missing field takes its default, or `nothing` when optional; extra keys are ignored | `conformance/run/json-decode-fields.em`, `conformance/run/json-decoding.em` |
| A private field is never read and must have a default | `conformance/run/json-decode-fields.em` (read side); the "must have a default" error: **none** |
| `JsonError` names line and column for trailing comma, single quotes, unquoted key, comment, NaN, unclosed string | `conformance/runtime-errors/json-invalid-text.em`, `src/Json.zig` (one test per mistake, e.g. `"trailing commas are refused by name"`) |
| Duplicate keys (including NFC-equal ones), nesting past 512, and too-large numbers are refused | `conformance/run/json-large.em`, `src/Json.zig: "keys that normalize to the same text are duplicates"`, `src/Json.zig: "a number too large for a Float is refused"` |
| Strict navigation and decode errors name the path and say missing or wrong kind | `conformance/run/json-errors.em`, `conformance/runtime-errors/json-decode-missing-field.em`, `conformance/runtime-errors/json-decode-wrong-kind.em` |

## 15.10 HTTP

| Rule | Covered by |
| --- | --- |
| `get`/`delete` take `query:`, `headers:`, `timeout:`, `strict:`; `post`/`put`/`patch` take one of `body:`, `json:`, `bytes:` | `conformance/http/http-api.em` |
| Passing more than one body raises | `conformance/http/http-errors.em` |
| Text and JSON bodies supply a content type unless `headers:` does | **none** (no case inspects the sent content type) |
| Query values are percent-encoded in dictionary order; `Http.encode_component` exposes it | `conformance/http/http-api.em` (query); `encode_component`: **none** |
| Redirects: at most five, the final address reported; a body is never resent | `conformance/http/http-api.em`, `conformance/http/http-errors.em` (loop), `src/Http.zig: "local HTTP transport handles responses, redirects, limits, and deadlines"` |
| Strict mode raises for 4xx/5xx keeping `HttpError.status`; `strict: false` returns the response | `conformance/http/http-errors.em`, `conformance/http/http-api.em` |
| Timeouts, non-UTF-8 text, and network and certificate failures raise | `conformance/http/http-errors.em`, `src/Http.zig: "HTTP maps DNS and certificate failures to teachable problems"` |
| `Response` fields, lowercase headers, case-insensitive `header(name)`, `json()` naming the address on failure | `conformance/http/http-api.em`, `conformance/http/http-errors.em` |
| Repeated headers join with `", "`, except `set-cookie` with a newline | `conformance/http/http-api.em` (`/headers`) |
| `bytes` is after content decoding; responses are at most 64 MB | `src/Http.zig: "local HTTP transport handles responses, redirects, limits, and deadlines"` |
| Only `http://` and `https://` are accepted | **none** |

## 15.11 CSV

| Rule | Covered by |
| --- | --- |
| `Csv.parse` gives every row as read; `parse_records` uses the first row as names | `conformance/run/csv-untyped.em`, `src/Csv.zig: "CSV parses ordinary and uneven rows"` |
| `parse_records` needs non-empty, unrepeated headers and equal-length rows; an empty document gives no records | `conformance/run/csv-errors.em` |
| A BOM, `\n`/`\r\n`, RFC quotes, and a one-grapheme separator are accepted | `src/Csv.zig: "CSV accepts a BOM Windows line endings and no final empty row"`, `src/Csv.zig: "CSV accepts a one-grapheme Unicode separator"`, `src/Csv.zig: "CSV parses quotes separators escapes and line breaks"` |
| `Csv.format` quotes minimally, uses `\n`, and adds no final newline | `src/Csv.zig: "CSV writes minimally quoted Unix rows"`, `conformance/run/csv-untyped.em` |
| `Csv.decode` binds columns by field name; extra columns ignored; missing or empty cells take defaults or absence; `""` for String | `conformance/run/csv-decode.em` |
| A missing or empty required field is a `CsvError` naming line and column | `conformance/run/csv-decode-errors.em` |
| Bool cells accept any capitalization | `conformance/run/csv-decode.em` |
| Private fields are never read and must have defaults | **none** |
| `Csv.encode` writes declaration-order public fields; absent optionals become empty cells; Floats keep `2.0` | `conformance/run/csv-encode.em` |
| Other field shapes are rejected before execution | `conformance/diagnostics/csv-decode-field.em`, `conformance/diagnostics/csv-encode-field.em` |
| `CsvError` has `line: Int?`; an invalid separator is a catchable `CsvError` | `conformance/run/csv-errors.em`, `conformance/runtime-errors/csv-invalid-text.em`, `src/Csv.zig: "CSV writer rejects a separator longer than one character"` |

## 15.12 Base64, hashing, and hexadecimal

| Rule | Covered by |
| --- | --- |
| Standard Base64 uses `+ /` with padding; URL-safe uses `- _` without | `conformance/run/base64.em` |
| Decoding ignores whitespace and rejects mixed alphabets, bad padding, and non-zero leftover bits; `decode_maybe` gives `nothing` | `conformance/run/base64.em` |
| Decoding accepts either padding form | `conformance/run/base64.em` |
| `to_hex()` writes lowercase; `from_hex` accepts either case; `from_hex_maybe` gives `nothing` for invalid or odd input | `conformance/run/bytes-hex.em`, `conformance/diagnostics/bytes-from-hex-wrong-type.em` |
| Base64, hex, and invalid UTF-8 failures raise `EncodingError` | `conformance/run/base64.em`, `conformance/run/bytes-hex.em` |
| `Digest.sha256` and `hmac_sha256` give stable 32-byte digests | `conformance/run/digest.em`, `conformance/diagnostics/digest-string.em` |

## 15.13 Structured tasks and channels

| Rule | Covered by |
| --- | --- |
| `Tasks.run` joins every child, including ones started while it waits; its result is the block's | `conformance/run/task-results.em`, `conformance/run/task-nested.em`, `conformance/run/task-cancel-new-child.em` |
| `start` returns `Task[T]` for the block's result type | `conformance/run/task-results.em` |
| At most 64 live children per execution, with the stated message | `conformance/runtime-errors/task-limit.em` |
| `start` needs an inline block | `conformance/diagnostics/task-inline-block.em` |
| A task block may name outer `const`s and parameters but not an outer `var`; the diagnostic names it | `conformance/diagnostics/task-capture.em`, `conformance/diagnostics/task-capture-assignment.em`, `conformance/run/task-capture-allowed.em` |
| `result()` waits, returns or raises, and can be called again after the group ends | `conformance/run/task-results.em`, `conformance/run/task-lifetime.em` |
| `done?()` checks without waiting; failure and cancellation count as done | `conformance/run/task-results.em` (success); failure/cancellation: **none** |
| Finished task records are reclaimed and leave scheduler scans | `conformance/run/task-lifetime.em`, `src/Scheduler.zig: "joining finished jobs removes them from scheduling scans"` |
| `wait(timeout:)` gives true or false without cancelling; zero only checks; negative raises | `conformance/run/task-wait.em`, `conformance/runtime-errors/task-negative-timeout.em`, `conformance/diagnostics/task-wait-arguments.em` |
| `Tasks.yield()` lets ready tasks run; pure computation is not preempted | `conformance/run/task-yield.em` |
| Ready tasks resume in readiness order; equal sleep deadlines in waiting order | `src/Scheduler.zig: "channel wakeups join the ready queue in readiness order"`, `src/Scheduler.zig: "equal sleep deadlines resume in waiting order"`, `conformance/run/task-sleep.em` |
| `Channel[T]` takes its type from context; `Channel[Int]()` is not an expression | `conformance/diagnostics/channel-types.em`, `conformance/diagnostics/generics-reserved-builtin-call.em` |
| Capacity zero is a rendezvous; positive capacity buffers | `conformance/run/channel-capacities.em`, `conformance/run/channel-backpressure.em`, `conformance/run/channel-fifo.em` |
| `close()` is idempotent; buffered messages stay; closed-and-empty gives `nothing`; a send raises | `conformance/run/channel-closed.em`, `conformance/runtime-errors/channel-send-closed.em` |
| Negative capacity raises with the stated message | `conformance/runtime-errors/channel-negative-capacity.em` |
| An optional item type is a checking error | `conformance/diagnostics/channel-optional.em` |
| `for item in channel` ends when closed and empty | `conformance/run/channel-iteration.em` |
| Sent collections and structs keep value semantics; objects and channels stay shared | `conformance/run/channel-values.em`, `conformance/run/channel-task-items.em` |
| `cancel()` acts at the next suspension point; cancelling a finished task does nothing | `conformance/run/task-cancellation.em` |
| `CancelledError` extends `Error`, not `RuntimeError` | `conformance/run/prelude-reach.em` |
| `finally` runs on cancellation, including cleanup that waits | `conformance/run/task-cancel-cleanup-waits.em` |
| Cancelling a parent cancels and joins its nested children | `conformance/run/task-group-cancellation.em` |
| A failing child cancels siblings and the block; the group propagates its first failure once | `conformance/run/task-errors.em` |
| An owner catching the failing child's `result()` sees the failure, which is not raised again | `conformance/run/task-errors.em` |
| Deliberately cancelled children do not fail the group; their `result()` raises `CancelledError` | `conformance/run/task-cancellation.em` |
| Program exit cancels and drains children | `conformance/run/task-cancel-exit.em` |
| Standard-input cancellation interrupts the wait; the line goes to the next input call | `conformance/run/task-cancel-input.em`, `conformance/run/task-cancel-input-live.em`, `src/Scheduler.zig: "a fixed input line stays available after its waiter abandons it"` |
| HTTP cancellation uses the deadline race | `conformance/http/task-http-cancellation.em` |
| File operations are not interrupted; cancellation arrives after they return | `conformance/run/task-file-operations.em`, `src/emerald.zig: "cancelled file opening closes the resource before invoking its block"` |
| A wait that cannot progress raises `DeadlockError` naming results or channel directions and locations | `conformance/runtime-errors/channel-receive-deadlock.em`, `conformance/runtime-errors/channel-send-deadlock.em`, `conformance/runtime-errors/task-self-wait.em`, `conformance/run/channel-deadlock-catch.em`, `conformance/run/task-deadlock-catch.em` |
| A pending timer, input, or host operation is not a deadlock | `src/Scheduler.zig: "a task waiting on outside work is not a deadlock"`, `conformance/run/task-deadlock-late.em` |

## 16.1 Annotations

| Rule | Covered by |
| --- | --- |
| `@test`, `@override`, `@abstract`, `@operator`, `@deprecated` attach to the declaration below; misplacement is an error | `conformance/diagnostics/inheritance-syntax.em`, `conformance/diagnostics/operator-annotation-placement.em`, `conformance/diagnostics/deprecated-owner.em` |
| `@deprecated` takes one string literal; an empty one is an error | `conformance/diagnostics/deprecated-not-literal.em`, `conformance/diagnostics/deprecated-empty.em`, `conformance/diagnostics/deprecated-duplicate.em` |
| Every use warns with the message; the declaration still works | `conformance/diagnostics/deprecated-uses.em`, `conformance/format/deprecated.em` |
| A use inside the deprecated declaration, or another deprecated one, does not warn | `conformance/diagnostics/deprecated-inside.em` |
| Overriding a deprecated method warns | `conformance/diagnostics/deprecated-override.em` |
| A constructor or a local cannot be deprecated on its own | `conformance/diagnostics/deprecated-constructor.em`, `conformance/diagnostics/deprecated-local.em` |
| A native built-in may be listed deprecated with the same message | **none** |
| The editor strikes deprecated uses through and shows the message in hover | `src/Lsp.zig: "a deprecated use is published struck through, with its correction in the message"`, `conformance/lsp/deprecated-hover.em`, `conformance/lsp/deprecated-completion.em` |
| Unknown annotations are errors with spelling suggestions | `conformance/diagnostics/inheritance-syntax.em`, `conformance/diagnostics/deprecated-misspelled.em` |

## 16.2 `assert`

| Rule | Covered by |
| --- | --- |
| A failure reports the source expression, values, and location, raising `AssertionError` | `conformance/runtime-errors/assertion.em`, `conformance/run/errors.em` |
| An optional message follows a comma; it must be a String | `conformance/runtime-errors/assertion.em`, `conformance/diagnostics/error-checking.em` |
| Equality assertions show both operands, each evaluated once | `conformance/runtime-errors/assertion.em` |
| Assertions stay active in optimized builds | **none** (CI runs ReleaseSafe, but no case is specific to it) |

## 16.3 Test discovery

| Rule | Covered by |
| --- | --- |
| `emerald test` runs `@test` functions; a test takes no parameters and returns nothing | `build.zig: tests_pass`, `conformance/diagnostics/error-checking.em` |
| A test must be a top-level function and takes no type parameters | `conformance/diagnostics/inheritance-syntax.em`, `conformance/diagnostics/generics-test-function.em` |
| Entry statements never run in test mode; an entry binding runs lazily only if a test reaches it | `build.zig: tests_pass` |
| One failure does not hide the remaining tests | `build.zig: tests_fail` |
| Output identifies the file, test name, failure expression, and stack trace | **none** (`build.zig: tests_fail` asserts only the exit status) |
| Tests run in deterministic order | **none** |

## 17.1 Default shape

| Rule | Covered by |
| --- | --- |
| A diagnostic shows location, source line, underline, and help in the canonical shape | `src/Diagnostic.zig: "renders the canonical shape from section 17.1"`, `conformance/diagnostics/definite-assignment.em` |
| Columns count Unicode scalars | `conformance/diagnostics/unicode-column-alignment.em`, `src/Source.zig: "locations are one-based and count scalars, not bytes"` |
| A warning shows `warning: ` and does not stop checking or execution | `src/Diagnostic.zig: "a warning renders its severity but keeps the same shape"`, `conformance/run/warning-does-not-block-execution.em` |
| `check`/`run`/`test` exit `1` when only warnings were found, and `run` still executes | `build.zig: check_reports_warning`, `build.zig: run_reports_warning_and_executes` |

## 17.2 Pedagogical behavior

| Rule | Covered by |
| --- | --- |
| `=` in a condition is explained as `==` | `conformance/diagnostics/assignment-in-condition.em` |
| Close spellings are suggested for names, methods, types, and annotations | `conformance/diagnostics/unknown-method.em`, `conformance/diagnostics/familiar-list-names.em`, `conformance/diagnostics/deprecated-misspelled.em`, `conformance/lsp/quickfix-name.em` |
| One primary error, no cascades | `src/emerald.zig: "one mistake produces one diagnostic rather than a cascade"`, `conformance/diagnostics/argument-errors-once.em`, `conformance/diagnostics/struct-member-habits.em` |
| A warning when indentation depicts a different brace scope, offering the formatter's indentation | **none** (no such warning appears in any case) |
| `emerald explain <code>` expands a coded diagnostic; an unknown code is a usage error | `build.zig: explains_unknown_name`, `build.zig: rejects_unknown_explanation` |

## 18.1 Initial CLI

| Rule | Covered by |
| --- | --- |
| Bare `emerald`/`--help` print the banner; `help <command>` gives usage | `build.zig: global_help`, `build.zig: run_help`, `build.zig: explain_help` |
| `emerald help lsp` documents `--stdio`; `lsp` is absent from the banner | **none** |
| An unknown command (including `new`) exits `64` | `build.zig: unknown_command` (`rn`); `new`: **none** |
| `--version` prints `Emerald 0.7.0-dev` | `build.zig: version_output` |
| `check` does not execute; `run` stops on source errors | `build.zig: check_does_not_execute`, `build.zig: run_stops_on_source_error` |
| Arguments after `--` reach `Program.arguments` for `run` and `test`; `check` rejects them | `build.zig: run_receives_arguments`, `build.zig: test_receives_arguments`, `build.zig: check_rejects_arguments` |
| Without `--`, `Program.arguments` is `[]` | `conformance/run/program-arguments.em`, `src/emerald.zig: "Program.arguments is empty by default, and each read is independent"` |
| Statuses: `0`, `1`, `2`, `3`, `64`, `66` | `build.zig` (`accepts`, `rejects`, `reports_runtime`, `tests_fail`, `format_misused`, `missing`) |
| Status `70` for an internal failure | **none** |
| `N tests passed.` on success | `build.zig: tests_pass` |
| `N tests, F failed.` after a run with failures | **none** (only the exit status is asserted) |

## 18.3 Formatter

| Rule | Covered by |
| --- | --- |
| One canonical output per project, normalized to `brace_style` | `src/Formatter.zig: "the formatter normalizes to Allman when a project asks for it"` |
| Braces inside strings and interpolation do not affect indentation | `conformance/format/strings.em` |
| The formatter refuses a file it cannot parse | `build.zig: format_rejects` |
| Block-comment interiors are reproduced byte for byte | `src/Formatter.zig: "a block comment's interior survives untouched, unlike a line comment"`, `conformance/format/comments.em` |
| Four-space indentation, no tabs | `conformance/format/blank-lines-and-indentation.em` |
| An empty body stays as `{ }` in either style; a comment-only body opens | `conformance/format/empty-bodies.em`, ``src/Formatter.zig: "an empty body stays on its header's line as `{ }` in both brace styles"`` |
| Blank-line runs collapse to one; no block opens or closes on a blank line | `src/Formatter.zig: "blank-line runs collapse to exactly one, and a block never starts or ends with one"` |
| Author line breaks are kept; a multi-line literal gains a trailing comma, a call does not | `src/Formatter.zig: "a call's multi-line arguments never gain a trailing comma, unlike a list literal"` |
| A same-line comment stays on its line | `src/Formatter.zig: "a comment on the same line as a statement stays there"` |
| Literals are copied verbatim from source | `conformance/format/strings.em` |
| Grouping parentheses are re-derived from precedence; `(-9223372036854775808)` keeps them before `.`, `(`, `[` | `conformance/format/operator-precedence.em`; the minimum-Int exception: **none** |
| `format <path>` formats the whole project | **none** |
| `--check` lists changing files and the command to apply, exits `1`, writes nothing | `build.zig: format_check_messy`, `build.zig: format_check_clean` (status only; the listed output: **none**) |
| A formatting run is silent when everything was canonical, else reports a count | **none** |
| Formatting canonical output again changes nothing | `src/Formatter.zig: "formatting already-canonical output is a no-op"`, every `conformance/format/` case |

## 18.4 REPL

| Rule | Covered by |
| --- | --- |
| Values persist across entries; each entry runs once and is never re-executed | `conformance/repl/basics.input`, `src/Repl.zig: "a file append executes once and its effect survives session teardown"` |
| Multiline input continues while a delimiter, body, multiline string, or block comment is open | `conformance/repl/multiline.input`, `src/Repl.zig: "an open block, case, or lambda asks for another line"` |
| Expressions echo unless `Nothing`; strings are quoted; `print("hi")` prints once | `conformance/repl/basics.input` |
| An optional `nothing` still echoes `nothing` | **none** |
| Prompt input and program `input` share one reader, across `:reset` | `conformance/repl/shared-input.input` |
| A `var` may be reassigned; a name may not be redeclared; diagnostics suggest `:reset` | `conformance/repl/errors-reset.input` |
| `:help`, `:reset`, `:quit` | `conformance/repl/errors-reset.input`, `conformance/repl/basics.input` |
| Locations are relative to their entry (`repl:1:9`) | `conformance/repl/errors-reset.input` |
| A failing entry runs nothing; a raising entry loses its declarations but keeps effects | `conformance/repl/declaration-rollback.input`, `conformance/repl/failed-code.input` |
| End of input exits | `conformance/repl/eof.input`, `conformance/repl/eof-input.input` |

## 18.5 Language server

| Rule | Covered by |
| --- | --- |
| Diagnostics, document symbols, formatting | `src/Lsp.zig: "document symbols cover a struct's members, an enum's values, and a trait's requirement"` |
| Hover, definition, references, rename with `prepareRename`, completion | `conformance/lsp/` (104 cases), `src/Lsp.zig` (45 tests) |
| Signature help with defaults and the active parameter | `conformance/lsp/signature-*.em` |
| Quick fixes come from structured data, for the current revision and range only | `src/Lsp.zig: "code actions use structured data and reject stale, unrelated, or malformed edits"`, `conformance/lsp/quickfix-*.em` |
| A document is checked with its whole project | `src/Lsp.zig: "a file in a project's subfolder is checked with its whole project"` |

## 19.2 to 19.6 Implementation architecture

| Rule | Covered by |
| --- | --- |
| A step budget stops a run at the host boundary, not as a catchable error | `src/emerald.zig: "a step-limited run stops even when Emerald catches ordinary errors"` |
| Every token and node carries a source span; stack traces use them | `src/emerald.zig: "a runtime error inside a function carries its stack trace"` |
| Cycles are reclaimed by the collector; external holders are roots | `src/Heap.zig: "a cycle is reclaimed, which counting alone cannot do"`, `src/Heap.zig: "collection keeps everything something outside the heap holds"` |
| Results do not depend on when collection happens | `conformance/run/many-closures.em` |
| Allocation failure is handled in every phase | `src/emerald.zig: "checking releases every allocation failure"`, `src/emerald.zig: "running releases every allocation failure"` |


## Notes on the spec found during the pass

These are not coverage rows, but they affect what area 3 should write a case against.

- **9.2 contradicts itself.** Its vocabulary list and the paragraphs after it specify `words`,
  `letter?`, and `digit?` (and they are implemented and tested), but a later sentence in the
  same section says "`words`, `title_case`, case-insensitive Unicode comparison, `letter?`, and
  `digit?` remain deferred".
- **17.1's list of "warnings currently reported" is stale.** It names four (nonexhaustive
  `case`, a known-true `is`, unreachable code, `@deprecated` uses), but the suite also checks
  warnings for casing (3.3), orphaned `##` (3.2), a known-false `is` (4.4), hiding a built-in
  (14.2), `using Emerald` (14.2), `equals`/`hash`/`to_string` without adopting their trait (8.4,
  15.1), and an unused type parameter (from `generics-design-plan.md`, not stated in
  rewrite-context at all).
- **17.2's indentation warning is stated as checker behavior but appears unimplemented**: no
  case or message produces it, so as written it is a rule with no possible passing case yet.
- **A stale help in the checker** (`src/Checker.zig`, the `?.` member path): "Method calls
  through `?.` arrive in the next optional-chaining slice", although 4.4 specifies them and
  `run/optional-object-reads.em` exercises them. Worth a diagnostics case.
- **Section citations drift in the cases**: `run/program-environment.em` and
  `diagnostics/program-environment.em` cite `Program.environment` as 15.10 (HTTP); the spec
  states it in 14.1.
- **18.1's test-runner text** is given as `N tests passed.`; the binary prints `1 test passed.`
  for one (`build.zig: single_test_passes`). Not a contradiction, but the singular is unstated.
- **Rules that cannot be tested by a program as written**: hash values may be seeded or change
  between runs (8.4); the recursion limit above 1,000 is a resource boundary (7.2); a GC
  fallback may close a forgotten handle "eventually" (13.3); allocation domains and the
  collector's design (19.4, 19.5); and the promise that documentation states each lossy
  optional operation's companion (4.5), which is about docs, not behavior. They are left out of
  the counts.

## Summary

- Total rules: **911**
- Covered: **774** (85%)
- With **none** (wholly or in part): **137** (15%)

Sections with the most uncovered rules:

| Section | Rules | None |
| --- | --- | --- |
| 14.1 Projects and entry points | 17 | 7 |
| 8.6 Rich vocabulary | 37 | 6 |
| 9.2 Initial string vocabulary | 29 | 6 |
| 11.5 Operator overloading | 16 | 5 |
| 4.4 Type relationships and conversion | 23 | 5 |
| 11.2 Composition and conflicts | 22 | 4 |
| 15.3 Files, directories, and paths | 20 | 4 |
| 15.9 JSON | 22 | 4 |
| 18.1 Initial CLI | 11 | 4 |
| 18.3 Formatter | 15 | 4 |
| 3.1 Files and encoding | 12 | 4 |
| 3.2 Comments | 8 | 4 |

### Worklist for area 3: the **none** rows

Each line is one rule to write a case for (or to record why it has none). Where a row was
partly covered, only the part marked **none** in its table needs a case.


**3.1 Files and encoding**

- The formatter writes UTF-8 "without a byte-order mark"
- The formatter "uses one consistent line-ending style" (CRLF input formats to one style)
- A line beginning with `..` does not continue the previous line
- "There is no backslash continuation syntax" (a trailing `\` is an error)

**3.2 Comments**

- Documentation warnings apply to program files, not the prelude
- An override without its own documentation inherits the overridden text, labelled with its source
- Several requirements with different text are each presented, not one chosen
- Private helper documentation does not become part of an adopter's public API

**3.3 Naming**

- The `?` result rule applies to overrides and the prelude too
- A leading underscore marks a private member; there is no `private` keyword

**3.4 Braces and parentheses**

- A bare anonymous block is not a standalone statement

**4.4 Type relationships and conversion**

- A mixed literal, `case`, or inline `if` of sibling classes infers the nearest shared base
- Classes sharing only a trait are not inferred to the trait
- Assignment through `?.` is rejected at check time
- A trait-typed value, struct, or enum receives no false warning
- A collection's `type_name` uses its static type

**4.5 Optional handling**

- A mutable property is not narrowed between reads
- A function returning `nothing` on some paths needs an explicit optional return type
- An optional-producing operation on an optional type yields that same type (no second layer)

**5.1 Literals**

- Indentation is removed before escapes, so an escaped `\n` is not a line break

**5.2 Boolean and comparison operators**

- Compound assignment evaluates receiver and index once, reads, then evaluates the right side

**5.3 Arithmetic**

- `x -3` is subtraction
- Compound assignment checks overflow
- `%` with a Float operand returns Float
- A NaN or infinite remainder operand produces NaN

**5.4 Calls, member access, and indexing**

- A slice start after its end is an error, not an empty result

**6.2 Conditional statements and expressions**

- Result types: Int/Float give Float, a `nothing` answer makes it optional, siblings infer their base
- There is no `unless` (it is not a keyword or construct)

**6.3 `case` and `when`**

- A nonexhaustive `Bool` statement case is a warning
- An explicit empty `else { }` acknowledges the gap
- Each arm has its own lexical scope

**6.4 Loops**

- Only a literal `true` counts for that rule
- Materializing the full `Int` domain with `to_list()` raises
- Equal inclusive endpoints visit once in every form; an equal half-open range is empty
- The wrong-side rule applies to `up_to`/`down_to` block forms

**6.5 Returns and guards**

- The warning also follows an `if`/`case` every branch of which cannot complete
- A nested function declared after a `return` is not unreachable

**7.1 Declaration**

- `->` is not part of the callable surface
- A nested function may not use `self`
- A nested function takes defaults and named arguments

**7.3 Defaults and named arguments**

- A second declaration of a function name in one scope is an error naming the first
- Users cannot write variadic functions

**7.4 Lambdas, trailing blocks, and capture**

- A bare capture of a higher-order method whose output type depends on a block needs an expected callable type

**8.3 Indexing and dictionary misses**

- An optional-valued dictionary reads a stored `nothing` and a miss alike, and `contains_key?` tells them apart
- Assigning `nothing` stores an entry and never deletes
- Stored value-type keys are copied, so later mutation of the original cannot break lookup
- `Hashable` does not make a class a key

**8.4 Equality and order**

- A `for` loop iterates the snapshot taken when it begins
- Runtime-colliding calculated keys: the later value wins without moving

**8.6 Rich vocabulary**

- Set operations use names; comparison operators do not mean subset
- `range.map` returns a completed list
- `take`/`drop` keep the receiver's kind for dictionaries and sets, in insertion order
- `take`/`drop` on a range return a list
- The non-bang forms work on a `const`; bang forms need a changeable list
- Strings and tuples do not get the general collection operations

**9.2 Initial string vocabulary**

- `capitalize()` returns an empty string unchanged
- A successful removal keeps the receiver's remaining original bytes
- `partition` with an empty separator is an error
- `replace` with an empty `old` is an error
- `to_float` accepts `Infinity`, `-Infinity`, and `NaN`
- A `String` keeps exactly the bytes it was built from; `File.read` then writing back reproduces them

**9.3 Numeric vocabulary**

- Both signed zeros answer false to `positive?()` and `negative?()`
- `Math.natural_log(0)` gives `-Infinity`
- `List.random()` and `Random.choose` give `nothing` for an empty List

**9.4 Standard-library recovery audit**

- Historical spellings `read_line` (as a prelude function), `slice`, `pad_left`/`pad_right`, `intersect`, and `Kernel` are rejected with Emerald's name

**10.1 Value and reference semantics**

- A class stored in a struct still compares by identity
- A class getter may change its object
- A struct method that changes only an object the struct holds does not change the struct

**10.3 Properties**

- A property runs on every read and is not cached
- The setter receives the proposed value through a read-only `value`
- Compound assignment runs the getter once and the setter once

**10.4 Type-level members**

- A type-level field is not narrowed

**10.5 Privacy**

- Equality and display still include private fields

**11.1 Trait purpose**

- Private members cannot satisfy public requirements

**11.2 Composition and conflicts**

- Inherited class methods outrank trait defaults
- Compatible duplicate requirements need one implementation; a writable property requirement subsumes a read-only one
- A conflict between traits is reported once, where they are first brought together
- `Trait.method(value)` may run a changing default only on an object

**11.3 Associated types and generics boundary**

- `Csv` does not encode or decode a generic type
- `Bytes` counts as `Equatable` and `Hashable`
- A generic value's `type_name` is its declaration's bare name

**11.5 Operator overloading**

- `@operator` belongs on a public instance method
- The method takes one required parameter and has an explicit result type
- An `@override` inherits its base registration and never repeats `@operator`
- `%`, `//`, `**`, and unary `-` are not overloadable
- The left operand may not be optional

**12. Enums and branching**

- A nonexhaustive enum statement case warns; an empty `else` acknowledges
- JSON, CSV, and `Console.table` refuse an enum carrying data

**13.2 Handling**

- A re-raised error keeps its original failure location

**14.1 Projects and entry points**

- A file outside a project runs alone; two exercises declaring `helper` do not collide
- `emerald run path/to/file.em` may select another entry
- The project root is the directory holding `main.em`, independent of the working directory
- Only the file's own directory is consulted; a subdirectory file run alone sees none of its project and names the entry to run
- Type-level fields initialize lazily; mentioning the type in an annotation or `using` does not
- A top-level `return` is allowed only in the selected entry file
- Statements after `exit()` are unreachable (warning)

**14.2 Namespaces and `using`**

- Diagnostics name built-in types bare
- `using` applies to the whole file wherever it appears
- `using` is file-local

**14.3 File shapes**

- An enum's nested types come after its values
- `Self` in a nested type's method means the nested type
- Reaching a nested type's type-level member sets up the nested type, not its encloser

**15.1 Philosophy**

- Assertion failures and runtime error text keep the field-based form

**15.2 Prelude**

- `input` keeps other whitespace, and Enter alone returns `""`
- A line that is not valid UTF-8 raises
- When standard output is styled and standard error is not, `print_error` strips the styling

**15.3 Files, directories, and paths**

- `File.exists?` and `Directory.exists?` are mutually exclusive for real paths
- `Directory.list` returns full paths of files and subdirectories together
- `write_lines` writes a newline after every line
- `write`, `write_binary`, `write_lines`, `append`, `create` create a missing file but no missing directory

**15.4 Regular expressions**

- A repeated group never takes an empty round; `\B` matches an empty text

**15.6 Platform libraries: Console**

- `--color` and `NO_COLOR` do not affect `clear`; `TERM=dumb` does

**15.8 Dates and times**

- `Weekday` does not adopt `Ordered`
- `TimeZone.local` is UTC by default for `check`, tests, and embedded runs

**15.9 JSON**

- Encode accepts a struct that holds itself (a tree)
- A private field is never written
- A class, function, or byte data is a checking error
- A private field is never read and must have a default

**15.10 HTTP**

- Text and JSON bodies supply a content type unless `headers:` does
- Query values are percent-encoded in dictionary order; `Http.encode_component` exposes it
- Only `http://` and `https://` are accepted

**15.11 CSV**

- Private fields are never read and must have defaults

**15.13 Structured tasks and channels**

- `done?()` checks without waiting; failure and cancellation count as done

**16.1 Annotations**

- A native built-in may be listed deprecated with the same message

**16.2 `assert`**

- Assertions stay active in optimized builds

**16.3 Test discovery**

- Output identifies the file, test name, failure expression, and stack trace
- Tests run in deterministic order

**17.2 Pedagogical behavior**

- A warning when indentation depicts a different brace scope, offering the formatter's indentation

**18.1 Initial CLI**

- `emerald help lsp` documents `--stdio`; `lsp` is absent from the banner
- An unknown command (including `new`) exits `64`
- Status `70` for an internal failure
- `N tests, F failed.` after a run with failures

**18.3 Formatter**

- Grouping parentheses are re-derived from precedence; `(-9223372036854775808)` keeps them before `.`, `(`, `[`
- `format <path>` formats the whole project
- `--check` lists changing files and the command to apply, exits `1`, writes nothing
- A formatting run is silent when everything was canonical, else reports a count

**18.4 REPL**

- An optional `nothing` still echoes `nothing`
