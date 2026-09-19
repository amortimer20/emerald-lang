# Standard-library inventory

> Status: in progress. Each row becomes a family page with signatures, semantics, a runnable
> example, and links to conformance cases; a linked family name below has one, an unlinked
> one is still a checklist row.

## Prelude functions

| API | Family page | Example/test source |
| --- | --- | --- |
| `print`, `write` | [Prelude](prelude.md) | `examples/greeter.em` |
| `input`, `input_maybe` | [Prelude](prelude.md) | `conformance/runtime-errors/input-ended.em` |
| `random`, `exit` | [Prelude](prelude.md) | `conformance/runtime-errors/random-empty-range.em` |
| `assert` | Errors and tests | `conformance/runtime-errors/assertion.em` |

## Built-in types and namespaces

| Family | Core surface to document | Example/test source |
| --- | --- | --- |
| [`Int`](int.md) | Arithmetic helpers, predicates, number theory, conversion, counting blocks | `conformance/run/int-methods.em` |
| [`Float`](float.md) | Rounding, classification, conversion, angles, square root | `conformance/run/float-methods.em` |
| [`Math`](math.md) | Constants, trigonometry, logarithms, powers | `conformance/run/math.em` |
| [`String`](string.md) | Unicode-aware queries, editing, splitting, conversion | `conformance/run/string-methods.em` |
| `List[T]` | Properties, reading, changing, higher-order, and shape methods | `examples/lists.em` |
| `Dict[K, V]` | Lookup, entries, keys/values, set-like operations, callbacks | `examples/dictionaries.em` |
| `Set[T]` | Membership, set algebra, callbacks | `conformance/run/set-operations.em` |
| Tuples | Positions, unpacking, equality | `examples/tuples.em` |
| [`Range`](range.md) | Iteration, `count`, `empty?()`, `step`, `reverse`, `to_list` | `conformance/run/range-values.em` |
| [`Random`](random.md) | Seeded range selection, choosing, and shuffling | `conformance/run/randomness.em` |

## Shared semantic labels

The eventual family pages must classify every entry under these headings rather than leaving
important behavior implicit:

| Label | Meaning | Initial examples |
| --- | --- | --- |
| **Changes** | Needs a `var`/changeable receiver; usually ends in `!` | `reverse!`, `append`, `merge` |
| **Optional result** | Returns `T?` | `List.first`, `find`, `String.index_of` |
| **Callback** | Takes a trailing lambda and specifies its invocation rules | `map`, `filter`, `each_with_index` |
| **Raises** | Fails only for particular runtime values | `Int.factorial`, `Range.to_list`, conversion methods |

## Completion rule

A family is complete only when every implemented public member has an entry, its example is
linked to executable repository coverage, and its mutation/optional/callback/error behavior
is explicit. The checker and interpreter remain the implementation authority while this
inventory is being filled; do not infer undocumented behavior from familiar languages.
