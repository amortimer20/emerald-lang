# The `Emerald` namespace: design and implementation plan

Status: design handoff, 2026-09-24, direction and all four decisions approved by the user. It does not authorize
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

## Decisions (settled by the user, 2026-09-24)

1. The bare built-in functions join the namespace: `Emerald.print` reaches the built-in even
   when a project declares its own `print`.
2. A project name that hides a built-in is a warning, whose help names the qualified form.
3. `using Emerald` is accepted but reported as redundant, since its names are already visible
   in every file; it should appear only where it is needed. Emerald has two severities, error
   and warning, so this is a warning worded as a hint, not a new diagnostic level.
4. Diagnostics keep showing built-in types by their bare names (`File`, not `Emerald.File`),
   for ease of reading.

## Slices

1. **Writable namespace.** Done, 2026-09-24. `Resolver.prelude_namespace` is now
   `Project.builtin_namespace` (`"Emerald"`), the interpreter's nine hardcoded
   `"emerald."` dispatch prefixes use it, and `Emerald` is registered as a namespace, so
   `Emerald.File.exists?(...)`, `Emerald.RuntimeError(...)`, annotations such as
   `Emerald.RuntimeError`, and aliases such as `using Handle = Emerald.FileHandle` resolve
   through the existing path code. Reserved: a root-level declaration named `Emerald` (an
   error at the declaration) and a top-level `emerald/` directory (refused by the project
   loader, which keeps a user file from ever sharing the prelude's namespace string, the
   resolver's only way to tell the prelude apart). `using Emerald` warns as redundant; the
   resolver had no warnings before, and `Resolved.ok()` counted any diagnostic as fatal, so
   it now counts only errors and resolver warnings are merged into the checker's report.
   Found on the way: a bad directory was reported only when some file also had a lex or
   parse error, since later stages returned only their own diagnostics; a lone `2bad/`
   passed `check` and even ran. Bad directories are now carried through to every report
   and stop execution. Unqualified names behave as before; the built-in functions,
   `Math`/`Program`, and the shadowing warning are slice 2.
2. **Consistent shadowing.** Done, 2026-09-24. The built-in functions are reachable as
   `Emerald.print` (and the rest of `Resolver.prelude`): keyed `Emerald.print`, apart from
   a program's own `print`, and mapped back to the built-in by `builtinFunctionName` in the
   checker and interpreter (`Interpreter.callBuiltin`); used as a value, the qualified form
   gets the bare form's "can only be called" error. `Math` and `Program` keep their special
   handling, now one helper (`qualifyBuiltinNamespace`), reachable bare unless a project
   namespace claims the name and always as `Emerald.Math`/`Emerald.Program`; the plan's
   "delete their special cases" was not needed, since they already behaved as the rule
   says. A project directory now wins over a prelude declaration of the same name
   (`file/`'s `File.read` is the project's), where before the built-in silently won. The
   shadowing warning covers module-level declarations and top-level directories, not
   locals, so a parameter named `input` stays quiet. The shadowed-trait operator error now
   also suggests `with Emerald.Ordered`.
3. **Documentation.** rewrite-context 14.2 and 15, the decision table, the language guide's
   projects page, and the library inventory; the handoff and journal.

Each slice ends with Debug and ReleaseSafe `zig build test`, `zig build`,
`bash tools/check-doc-examples.sh`, and `git diff --check`, with new conformance cases read by
hand.
