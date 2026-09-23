# Diagnostics

Emerald's diagnostics point at the source text, say what Emerald understood, and suggest a
concrete correction. Some common checking problems also show a code in square brackets:

```text
main.em:1:7: [E1001] `total` is not defined
  print(total)
        ^^^^^
Check the spelling, or declare it before this line.
```

Use that code to ask for a worked explanation:

```text
emerald explain E1001
```

The first catalog is deliberately small. A code appears only where Emerald has a maintained
example to teach the underlying idea; diagnostics without a code are still complete and should
be read in the same way.

| Code | Meaning |
| --- | --- |
| `E1001` | A name is not defined |
| `E2001` | A value does not fit its declared type |
| `E3001` | Code tries to change a `const` |
| `E4001` | A value has no requested member |

`emerald explain` requires a code. A bare form is intentionally not supported: each command
run is independent, and Emerald does not guess which earlier terminal output a reader means.
Run `emerald help explain` for its command syntax.
