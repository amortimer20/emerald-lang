# Tuples

A tuple groups a fixed, ordered set of differently typed values; its shape is part of its
type, written `(String, Int)`, and it needs at least two elements — `()` is not a value at
all, and `(value)`/`(value,)` are ordinary grouped expressions, never a one-element tuple.
Run [`examples/tuples.em`](../../examples/tuples.em) for the everyday shape of everything
below, and [`conformance/run/tuples.em`](../../conformance/run/tuples.em) and
[`conformance/run/tuple-unpacking.em`](../../conformance/run/tuple-unpacking.em) for further
conformance coverage.

## Literal and positions

```emerald
const entry: (String, Int) = ("score", 10)
print(entry.0, entry.1)
```

Positions are zero-based member access, not a method call. `entry.0.1` reaches a position of
a position: the lexer reads `0.1` as one number and the parser splits it back into two
positions, so writing it out works exactly as it looks.

**Raises** nothing here — an invalid position is a checking-time error, not a runtime one:
see [`conformance/diagnostics/tuple-position.em`](../../conformance/diagnostics/tuple-position.em)
(`(String, Int) has no position 2`).

## No `count`

A tuple has no `count` property: its size is fixed in its type, written where the tuple is,
so there is nothing to ask at runtime. See
[`conformance/diagnostics/tuple-has-no-count.em`](../../conformance/diagnostics/tuple-has-no-count.em).

## Widening

Unlike a `List`, which is invariant because it can be written through (4.4), a tuple widens
position by position: a `(Int, Int)` may be used where a `(Float, Int)` is expected.

## Equality

`==` compares position by position, so two tuples built separately are equal exactly when
every position is: `("a", 1) == ("a", 1)` is `true`.

## Destructuring

```emerald
const (name, age, active) = result
for (day, count) in readings { ... }
readings.each { (day, count) => ... }
(first, second) = (second, first)
```

Destructuring works the same way in a declaration, a `for` binding, a block's parameters, and
assignment to existing names, and must match the tuple's arity exactly. `_` discards a
position anywhere a tuple is unpacked, and a position may itself be a nested tuple pattern:
`const (label, (x, y)) = entry`. In an assignment, the whole right side is evaluated before
any destination changes, so `(first, second) = (second, first)` genuinely swaps them.

**Raises** nothing — unpacking a non-tuple, or the wrong arity, is a checking-time error. See
[`conformance/diagnostics/not-a-tuple.em`](../../conformance/diagnostics/not-a-tuple.em) and
[`conformance/diagnostics/tuple-arity.em`](../../conformance/diagnostics/tuple-arity.em).
