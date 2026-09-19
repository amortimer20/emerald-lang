# Core language

> Status: outline. Examples in this guide should link to executable repository examples as
> they are added.

## Start here

```emerald
var name = input("What is your name? ")
print("Hello, #{name}!")
```

`var` declares a changeable binding. `print` displays values, and `#{...}` evaluates an
expression inside a string. See [`examples/greeter.em`](../../examples/greeter.em).

## Guide outline

### Bindings and values

- `var` and `const`
- Type inference and explicit annotations
- `Int`, `Float`, `Bool`, `String`, `Nothing`, and `T?`
- Display, equality, and interpolation

### Expressions

- Arithmetic, comparison, and logical operators
- Method calls and properties
- Assignment and compound assignment
- Parentheses and evaluation order

### Control flow

- `if` / `else`, `while`, and `for`
- Ranges and loop bindings
- `break`, `continue`, and `return`
- `case` / `when`

### Functions and blocks

- Declaring and calling `func`
- Parameters, defaults, and named arguments
- Lambdas, trailing blocks, captures, and function values

### Next guides

The later guides will cover collections, objects, errors, tests, and projects. Their behavior
is already implemented; this outline is intentionally not a claim that those reference pages
exist yet.
