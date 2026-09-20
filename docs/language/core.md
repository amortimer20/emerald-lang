# Core language

This guide covers the syntax you need for an ordinary Emerald program: bindings,
values, expressions, control flow, and functions. Each section links a runnable
example rather than repeating one that might drift from the implementation; run
the linked file with `emerald run <path>` to see it for yourself.

## Start here

```emerald
var name = input("What is your name? ")
print("Hello, #{name}!")
```

`var` declares a changeable binding. `print` displays values, and `#{...}` evaluates an
expression inside a string. See [`examples/greeter.em`](../../examples/greeter.em).

## Bindings and values

`var` declares a binding that can be reassigned; `const` declares one that cannot.
Both usually infer their type from the initializer:

```emerald
var score = 0
const limit = 100
```

An uninitialized binding needs an explicit type, and reading it before every
branch has assigned it is a checking error, not a runtime one — Emerald proves
definite assignment ahead of time. See
[`conformance/run/bindings.em`](../../conformance/run/bindings.em) for `var`,
`const`, and the compound assignments (`+=`, `-=`, `*=`, `/=`, `//=`).

The initial value types are `Bool`, `Int`, `Float`, `String`, `Nothing`, and the
collection, function, and user-defined types the later guides cover. `Int` is a
checked 64-bit signed integer and `Float` is IEEE-754 binary64. `Nothing` is the
type of the single value `nothing`; a trailing `?` on a type, as in `Int?`,
means the value may be absent, and the [types and optionals guide](README.md)
(planned) covers reading one safely. `print` and string interpolation display
every built-in type readably, and `==` compares by value.

## Expressions

Arithmetic uses ordinary precedence: `+`, `-`, `*`, `/` (always `Float`), `//`
(floor division), `%` (the matching remainder), and `**` (exponentiation, which
binds tighter than unary minus and is right-associative). Two `Int` operands
keep `//`, `%`, and `**` as `Int`; either operand being `Float` makes the
result `Float`. Every `Int` operation is checked for overflow. See
[`conformance/run/division.em`](../../conformance/run/division.em) and
[`conformance/run/exponentiation.em`](../../conformance/run/exponentiation.em).

Comparisons (`==`, `!=`, `<`, `<=`, `>`, `>=`) and the word operators `not`,
`and`, and `or` read like ordinary English rather than symbolic duplicates
(`!`, `&&`, `||` are not a second spelling). Comparisons chain:
`0 <= score <= 100` evaluates `score` once and short-circuits like `and`. See
[`conformance/run/comparison.em`](../../conformance/run/comparison.em).

Method calls use parentheses, a property uses none, and there is no separate
pipeline operator because chaining already reads left to right:

```emerald
input("Age: ").trim().to_int_maybe().or(0)
```

Assignment is a statement, never an expression, so `if x = 5` is rejected
rather than silently assigning. Compound assignment reads its target once,
computes, and assigns; see the same
[`conformance/run/bindings.em`](../../conformance/run/bindings.em) example
above. Parentheses group evaluation order exactly as expected wherever
precedence alone would give the wrong grouping.

## Control flow

`if`/`else` is the ordinary statement form, with an `if ... then ... else`
expression form for a single value and a trailing `if` guard for one simple
statement on its own line (there is no `unless`; write `if not`). See
[`conformance/run/conditionals.em`](../../conformance/run/conditionals.em) and
the guard clauses throughout
[`examples/loops.em`](../../examples/loops.em).

`case`/`when` compares a subject against alternatives top to bottom with `==`
and runs the first match, or (with `then`) produces a value and must cover
every case. A subjectless `case` treats each `when` as a `Bool` condition. See
[`conformance/run/case.em`](../../conformance/run/case.em).

`while` and `for` are the two loops, with `break` and `continue`. `for`
iterates a list, a string, or a range. Ranges only ever count upward (`1..5`
inclusive, `1..<5` exclusive), which is what makes a computed bound like
`0..<items.count` safe on an empty list; counting down is written in words
with `down_to`, and `step`/`reverse` adjust either direction. See
[`examples/loops.em`](../../examples/loops.em) and
[`conformance/run/counting.em`](../../conformance/run/counting.em).

`return` leaves the nearest function (not an enclosing one, when written
inside a lambda). A branch that always returns is excluded from definite
assignment, so ordinary guard-clause functions type-check. See
[`conformance/run/early-return.em`](../../conformance/run/early-return.em). A bare `return`
with no enclosing function is legal only at a program's own top level, where it ends the
program instead — see [Errors, tests, and projects](errors-tests-and-projects.md#ending-the-program-early-and-reading-its-arguments).

## Functions and blocks

`func` declares a named function with a colon-introduced return type; a
function with no `return`ed value has return type `Nothing` and may omit it.
Parameters are read-only, and a collection or struct parameter is the
function's own copy, so mutating it is rejected — the fix is to return the
changed value. See [`examples/functions.em`](../../examples/functions.em),
which also shows recursion and a nested function sharing its enclosing
block's variables.

Default-valued parameters follow required ones, and a named argument can skip
straight to one further along:

```emerald
func greet(name: String, punctuation: String = "!", times: Int = 1) {
    for _ in 1..times {
        print("Hello, #{name}#{punctuation}")
    }
}

greet("Ava")
greet("Bo", times: 2)
```

See
[`conformance/run/defaults-and-named-arguments.em`](../../conformance/run/defaults-and-named-arguments.em).

Lambdas are values written with `=>`, and a trailing block passed to a call is
the same thing without a second calling convention:

```emerald
numbers.each { number => print(number) }
```

A lambda closes over the surrounding variables by reference, so a block can
read and change them, and a loop variable is fresh every iteration so blocks
made inside a loop each keep their own value. A named function is a callable
value too, and omitting a method's call parentheses captures it the same way.
See [`examples/blocks.em`](../../examples/blocks.em),
[`conformance/run/lambdas.em`](../../conformance/run/lambdas.em), and
[`conformance/run/closures.em`](../../conformance/run/closures.em).

## Next guides

The later guides will cover collections, objects, errors, tests, and projects. Their behavior
is already implemented; this outline is intentionally not a claim that those reference pages
exist yet.
