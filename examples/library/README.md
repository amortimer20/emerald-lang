# A library to copy

`geometry/` is a small Emerald library laid out the way rewrite-context 14.4 asks, so it can be
shared by copying, with no package manager:

- **It refers to itself by its own name.** Its files write `Geometry.Shapes.Circle`, never
  `Shapes.Circle`, because a namespace path starts at the project's top. The paths still hold
  once the folder is copied to the top of another project.
- **It has no top-level code.** Only a project's own `main.em` runs, so a library holds
  declarations only.
- **This directory is a project that contains it.** `main.em` here is the library's demo, and
  runs it with `emerald run examples/library/main.em`.

To use the library, copy `geometry/` (only that folder) next to your own `main.em`, then write
`Geometry.area(...)` or `using Geometry`. The version you have is the one you copied; to update
it, copy it again. Note where it came from, so you know where to look.
