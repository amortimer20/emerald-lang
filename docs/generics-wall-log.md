# Generics wall log

**Retired as a gate (the user, 2026-10-28).** This log was the evidence gate for
[generics-design-plan.md](generics-design-plan.md) (section 3): generics were to be built only if
it showed a real need. The user chose to build them without waiting, and they are merged (PR #44),
so the gate has no job left. The log stays as a record, and from now on it collects **friction**:
real programs where generics as built are awkward, wrong, or missing something, reviewed at the
1.0 review while the design can still change. A made-up example does not count; a program someone
actually wanted to write does.

The text below is the log as it stood while it was a gate, kept for its reasoning: an entry each
time a real program, classroom example, or QA program could not be written without copy-pasting a
type-specific version of a class, enum, or function. Generics were to be built only if it showed
about a dozen entries from at least three different shapes, or one data-structures program the user
wanted to ship in `examples/` and could not.

Entries are append-only. Do not remove one because it was later worked around; note the
workaround in the entry instead.

## Entry format

```
### YYYY-MM-DD: short title
- Who and where: the program, who wanted it, and where it lives (a path, a PR, a classroom).
- Shape: the container or helper it needed (linked list, tree, grid, cache, a function over any
  ordered type, and so on).
- Types it needed to work with: for example `Int` and `String`.
- Needed an order, equality, or hash on the element: yes or no, and which.
- Workaround and its cost: one class per type, `List` and tuples, a callback, or nothing worked.
- Notes.
```

## Entries

(None were recorded while it was a gate.)

## Friction

Each entry: the date, the program and where it lives, what was awkward, and what was done about it.

### 2026-10-26: Program 6 joined lists with `+`
- The plan's binary search tree (`generics-design-plan.md` section 7) wrote
  `left.items() + [item] + right.items()`. Emerald has no `+` on lists; `chain` joins them.
- Not a generics problem, but a sign that tree-shaped generic code reaches for list
  concatenation. Worth watching for in classroom programs before deciding whether `+` on lists
  earns a place.
