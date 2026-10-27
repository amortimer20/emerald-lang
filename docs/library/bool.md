# Bool

`true` and `false`. Conditions require a `Bool` (4.4); there are no truthy or falsey values,
and `true < false` is rejected because a `Bool` has no order.

## to_string() -> String

`"true"` or `"false"`, exactly as `print` shows it.

## equals(other: Bool) -> Bool

Whether the receiver and `other` are equal, as `==` decides. With `hash`, it is what lets a
generic declaration that requires `Equatable` or `Hashable` (rewrite-context 11.3) take a
`Bool`.

## hash() -> Int

A number for the value, equal for equal values, as a dictionary or set uses it. It is a runtime
detail (8.4): it can change between runs and releases, so never store or display it.

See [`conformance/run/generics-constraints.em`](../../conformance/run/generics-constraints.em).
