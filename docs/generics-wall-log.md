# Generics wall log

The evidence gate for [generics-design-plan.md](generics-design-plan.md) (section 3). Add an
entry each time a real program, classroom example, or QA program cannot be written without
copy-pasting a type-specific version of a class, enum, or function. A made-up example does not
count; a program someone actually wanted to write does.

Generics are built only if this log shows a real need: about a dozen entries from at least three
different shapes (not twelve stacks), or one data-structures program the user wants to ship in
`examples/` and cannot. The log is reviewed at the 1.0 review, or sooner if the user asks. If it
stays short, 1.0 ships without user generics.

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

(None yet.)
