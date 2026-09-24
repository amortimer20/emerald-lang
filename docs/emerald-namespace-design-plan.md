# The `Emerald` namespace: design and implementation plan

Status: design handoff, 2026-09-24, direction approved by the user. It does not authorize
implementation, commits, or pushes by itself. Read AGENTS.md and the current handoff before
acting; at the start of each slice, reread `git status`, the recent `git log`, and
docs/handoff.md. Scheduled after nested types (`docs/nested-types-design-plan.md`), since the
platform libraries need both.

## Problem

A project name that matches a built-in is handled three different ways today:

- A declaration such as `struct File` wins: the file's own names always replace a prelude
  name (`Resolver.offerKey`).
- A `math/` or `program/` directory wins, deliberately: `Math` and `Program` are special-cased
  in `Resolver` (around `qualify`'s `Program`/`Math` checks) and yield when a project
  namespace owns the name.
- A `file/`, `random/`, or `path/` directory silently loses: the prelude class wins and the
  project's namespace becomes unreachable through that name.

Reserving every built-in name would fix the inconsistency, but would make each new platform
library (Console, Tui, Graphics, Gui, Audio, Game) a breaking change for any project already
using its name.

## Accepted direction

Built-ins live in one real, writable namespace, `Emerald`, implicitly imported into every
file (the model of C#'s implicit `using`s). Names the project declares still win; the built-in
stays reachable qualified:

```emerald
struct File {
    var name: String
}

const mine = File("notes")                  # the project's File
const text = Emerald.File.read("notes.txt") # the built-in
```

- **One reserved name.** `Emerald` itself is reserved: a directory, namespace, or
  module-level declaration named `Emerald` is an error. Nothing else is, and the set never
  grows, so adding a built-in never breaks a program.
- **The project always wins,** for declarations and directories alike, removing the silent
  `file/` case.
- **A warning when a project name hides a built-in,** with the way back in its help:
  "`File` hides Emerald's built-in `File`; write `Emerald.File` to reach it." A beginner who
  names a type `File` by accident still finds out.
- **Everything built-in lives there:** the `prelude.em` classes and traits, `Math` and
  `Program` (moved out of their resolver special cases), future platform libraries
  (`Emerald.Console.Color`), and, to leave the rule no exceptions, the bare functions in
  `Resolver.prelude` (`print`, `write`, `input`, `input_maybe`, `random`, `exit`).

## Verified starting point (2026-09-24)

- The prelude already has an internal namespace: `Resolver.prelude_namespace = "emerald"`,
  keys such as `emerald.File`, visible bare in every file under the file's own names. It is
  lowercase specifically so no program can write it. About 28 references across Resolver,
  Checker, Interpreter, Lsp, and emerald.zig go through `prelude_namespace`, `preludeKey`, or
  `isPreludeKey`, so the key prefix changes in one place.
- `Math`/`Program` use their own key constants (`math_pi_key`, `program_arguments_key`, the
  `Math.` function prefix) in Resolver, Checker, and Interpreter, outside the prelude.
- `Float.infinity`/`Float.nan` are type-level constants on the built-in `Float` type, not a
  namespace, and stay as they are.
- No program in the tree declares `Emerald`; it appears only in comments and strings.

## Decisions to settle before slice 1

1. Whether the bare built-in functions join the namespace (recommended: yes, `Emerald.print`)
   or stay a separate, unshadowable list.
2. Whether shadowing a built-in is a warning (recommended) or silent.
3. Whether `using Emerald` is accepted as a harmless no-op or reported as redundant.
4. How diagnostics display built-in types: unchanged bare names (`File`), recommended, since
   `Emerald.` would add noise to every beginner's first error.

## Slices

1. **Writable namespace.** Rename the internal prefix to `Emerald`, accept `Emerald.X` paths
   in expressions and annotations, and reserve `Emerald`. Behavior for unqualified names is
   unchanged.
2. **Consistent shadowing.** Project directories win over built-ins; move `Math` and
   `Program` into the namespace and delete their special cases; add the shadowing warning.
3. **Documentation.** rewrite-context 14.2 and 15, the decision table, the language guide's
   projects page, and the library inventory; the handoff and journal.

Each slice ends with Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh`, and `git diff --check`, with new conformance cases read by
hand.
