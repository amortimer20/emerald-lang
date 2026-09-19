# Standard-library reference

This is the source reference for the API Emerald programs can use today. Start with the
[inventory](inventory.md), which is the checklist for the family pages that follow.

## Reference conventions

```text
method(arguments) -> Result
```

- `T?` means the result may be `nothing`.
- A trailing `!` marks an operation that changes its receiver.
- `block { item => ... }` describes a trailing lambda callback.
- **Raises** calls out failures that depend on values rather than static types.

The first complete family pages should cover `List`, `Dict`, `Set`, `String`, `Int`, `Float`,
`Range`, `Math`, and the prelude functions. User-defined structs, classes, traits, and enums
belong in the language guide rather than this built-in catalog.
