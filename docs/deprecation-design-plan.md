# Deprecation: design plan

Status: accepted, 2026-10-28. The user accepted every recommendation below as proposed in
conversation the same day. Building has not started; it waits for the user's go-ahead.

Emerald 1.0 starts a compatibility promise (handoff, roadmap item 13), and a promise needs a way
to retire things: a name that was a mistake, a method replaced by a better one, a spelling the
language moves away from. Today there is none. Section 16.1's annotation set is deliberately
small, and nothing warns before something is removed. This plan adds the smallest mechanism that
lets a program learn, in plain words and before anything breaks, that something it uses is going
away and what to use instead.

## Recommendations at a glance

| Decision | Recommendation |
| --- | --- |
| 1. Mechanism | `@deprecated("message")` on a declaration, with one literal string saying what to use instead |
| 2. Where it can go | Functions, methods, type-level functions, structs, classes, enums, traits, fields, properties, enum values, type-level fields, and module-level bindings |
| 3. Effect | A warning at every use, carrying the message; nothing else changes |
| 4. Exit status | Consistent with every other warning: `run`, `check`, and `test` exit `1` |
| 5. Language features | Retiring syntax or behavior is a checker warning in the same shape |
| 6. Built-ins | Prelude declarations use the annotation; natives get a `deprecated` field in the catalog and the checker |
| 7. Editor | Struck-through names (LSP's `Deprecated` tag) and the message in hover and completion |
| 8. Policy | Before 1.0: one release with a warning before removal, listed in the release notes. After 1.0: a minor release may deprecate; only a major release removes |
| 9. Left out | No `since:` or removal-date arguments, no deprecation levels, no way to silence one warning |

## 1. The annotation

```emerald
@deprecated("Use `append` instead.")
func push(item: Int) {
    self.append(item)
}
```

- It takes exactly one argument, a string literal, as section 16.1 requires of annotation
  arguments. The string is the correction, written for the reader of the warning: what to use
  instead, or why there is nothing to use. An empty string is an error, since a warning that
  says nothing teaches nothing.
- It goes on the declarations listed in the table. A declaration takes it once.
- The formatter writes it on its own line above the declaration, as `@override` is written.

## 2. What it does

Every use of a deprecated declaration is a warning at the use, in section 17.1's shape:

```text
main.em:9:5: warning: `push` is deprecated
  bag.push(3)
      ^^^^
Use `append` instead.
```

- **A use** is any reference the checker resolves to the declaration: a call, a read, a type
  written in an annotation, a construction, a captured method, an enum value, an operator that
  selects an annotated method.
- **Not a use:** the declaration itself, and uses inside another deprecated declaration, so
  retiring a family of related names does not warn about each one's use of the others.
- **Overriding** a deprecated method, or supplying a deprecated trait requirement, warns at the
  override: the override keeps the old name alive.
- Nothing else changes. The program checks, runs, and behaves as before.

## 3. Exit status

Section 17.1 makes any warning end `check`, `run`, and `test` with status `1` once nothing more
specific took priority, so a warning is never silently missed. A deprecation follows the same
rule. It does change the status of a program that used to pass, which matters to a script or CI
job that checks it; that is the point, since a deprecation is something to act on. Release notes
that deprecate something say so in their "Upgrading" section.

## 4. Retiring language features

Syntax and behavior have no declaration to annotate. Retiring one is a checker warning in the
same shape, `this ... is deprecated`, with the correction as its help, added in the release that
starts the deprecation and listed in its notes. The same policy (section 7) applies.

## 5. Built-ins

- A built-in written in the prelude (`src/prelude.em`) takes the annotation like any program
  declaration.
- A native built-in member gets a `deprecated` field (the message) in `src/builtins.json`, and the
  checker's list of native members reads it, so the warning, the editor, and the website parity
  check agree. The built-in members rule in AGENTS.md (checker, interpreter, hint text, docs)
  applies: a deprecated native keeps working, and its page says it is deprecated and why.

## 6. The editor

- A deprecated use is published with LSP's `Deprecated` diagnostic tag, which editors draw struck
  through, as well as the warning.
- Hover on a deprecated declaration or use starts with the message.
- Completion still offers deprecated members, marked deprecated, after the others.

## 7. Policy

- **Before 1.0:** the language may still remove things outright (rewrite-context section 1), but the practice is
  one release that warns before the release that removes, and both releases' notes list it.
- **After 1.0:** a minor release may deprecate; only a major release removes. A deprecation names
  its replacement whenever there is one.

## 8. Left out on purpose

- **`since:` and removal versions.** The release notes and the message carry them. Two more
  arguments would be two more things to keep accurate.
- **Levels** (a soft and a hard deprecation). One kind, a warning, is enough to act on.
- **Silencing one warning** (an `@allow` or a pragma). A program that must keep using something
  deprecated keeps the warning as a reminder; section 17.2 asks that warnings stay scarce enough
  to read, which is the deprecating side's job.

## 9. Build order, when the user says go

1. **The annotation and its warning:** parser, checker (every kind of use in section 2, overrides,
   the empty-message error), formatter, diagnostics cases, rewrite-context 16.1 and 17.1.
2. **The editor:** the `Deprecated` tag, hover, completion.
3. **Built-ins:** the catalog field, the checker's native list, the website parity script, and the
   library and website pages.

Each slice ends runnable, with conformance cases, the handoff, and the journal updated, as
AGENTS.md's workflow describes.

## Decisions (accepted 2026-10-28)

Every recommendation in the table above, including exit status kept consistent with other
warnings (section 3) rather than exempting deprecations.

## Settled while building

(Nothing built yet.)
