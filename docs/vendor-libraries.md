# Adding a vendor library

A **vendor library** is a native library someone else wrote, shipped with Emerald behind an
Emerald-shaped API: `Graphics` on raylib is the first. This page is the recipe for adding
one. The reasons behind it are in
[`vendor-libraries-design-plan.md`](vendor-libraries-design-plan.md); this page says what to
do. The test-only library [`vendor/selftest`](../vendor/selftest/) is a working example of
every step, and [`vendor/_template`](../vendor/_template/) is a copy of it to start from.

## Should it be a vendor library?

Only the user decides which libraries come in. The questions to bring to them:

- **License.** One Emerald can ship: MIT, zlib, BSD, public domain. Not GPL, which would
  change Emerald's own terms.
- **Build.** Zig builds it from source with nothing installed beyond the operating system's
  own development packages.
- **Runtime.** No dependency a beginner would have to install. System libraries the
  operating system already has (a window system, a sound server) are fine.
- **Surface.** Small enough to curate into an Emerald-shaped API, not a thin wrapper that puts
  C names, null returns, and integer error codes in a student's code.
- **Testing.** A way to run it without a screen or a device, so CI can test it.

## The shape of one

A library is a shared module (`emerald-<name>.dll`, `libemerald-<name>.so`, or `.dylib`) that
Emerald loads the first time a program calls into it, plus Emerald declarations that join the
prelude only when a program names one of the library's types. A program that never names it
pays nothing: not startup time, not memory, not a download that fails.

Three files make it up, in `vendor/<name>/`:

- `<name>.c` or `<name>.zig`: the **glue**, a function per native, over the upstream library.
- `<name>.em`: the **declarations**, the Emerald API a beginner sees.
- `build.zig`: builds the module.

The module and Emerald talk through [`vendor/emerald_module.h`](../vendor/emerald_module.h):
the module exports one function, `emerald_module`, that returns a table of natives. A native
takes and returns `nothing`, a `Bool`, an `Int`, a `Float`, a `String`, or `Bytes`. Nothing
richer crosses: no pointers, no lists, no callbacks into Emerald. A window, an image, or a
sound stays inside the module and crosses as an `Int` handle.

## Steps

1. **Copy the template.** `cp -r vendor/_template vendor/<name>`, rename `example.c` and
   `example.em` to `<name>.c` and `<name>.em`, and replace `example` and `Example` throughout
   (the library's name, its type names, its error type, its module name).
2. **Fill in `README.md`.** Every heading: upstream, what is exposed, what is left out and
   why, the build, the testing. `tools/check-vendor.sh` fails on a missing heading.
3. **Pin the upstream source** (a library with upstream code only). From the repository root,
   `zig fetch --save=<name> <url>#<exact tag or commit>`. This writes a lazy dependency with
   its hash to `build.zig.zon` (create it first if the repository has none: a name, a
   fingerprint Zig prints, and `.minimum_zig_version`). Also list in `build.zig.zon` every lazy
   dependency of the dependency that the platform you build on asks for: the raylib spike
   found that a native macOS build asked for one and stopped at configure time until it was
   listed. `zig-pkg/` holds fetched packages and is ignored by Git. Add the license text to
   `THIRD_PARTY_NOTICES.md`.
4. **Write the glue.** One function per native in the table. Check every argument, and
   return `em_error` for every failure, never abort or print. An error's first line is the
   message and later lines say what to try; write them for a beginner:
   `"`ship.png` is not there.\nIs it in the same folder as the program?"`. Text, bytes, and
   messages you return belong to the module until the next call; Emerald copies them at once.
   Turn off the upstream library's own logging, so no C text reaches a terminal.
5. **Write the declarations.** For each native, a private function (a name that starts with
   `_`) whose body is a stand-in, with a comment that starts `# Native:` just above it:

   ```text
   # Native: the sum of two integers.
   func Example._add(first: Int, second: Int): Int { return 0 }
   ```

   The module's entry `Example::_add` runs in its place. Then write the public API as
   ordinary Emerald over the natives: named arguments, defaults, enums, doc comments (`##`),
   and an error type that extends `Error`. Rules the checker enforces on every declaration:

   - A native belongs to the type that calls it (privacy follows the type, 10.5).
   - A type that holds a handle keeps it in a private `_id` field and builds its own values in
     a function of its own type, as `Stopwatch.start` does, because a private field cannot be
     set from outside.
   - `nothing`, `true`, and the other keywords are not names.
   - Write the library's names with its namespace as `Emerald.Name`, as the prelude does.
6. **Register it.** Set `.names` in `build.zig` to every type and namespace the library
   declares (a program that writes any of them loads it) and `.error_type` to its error type,
   then add one line to `vendor/libraries.zig`: `@import("<name>/build.zig").library,`.
7. **Test it.** Cases under `conformance/vendor/<name>/` (programs and `.expected` output) and
   `conformance/vendor-errors/<name>/` (programs that end in a raised error), and a
   diagnostic or two under `conformance/diagnostics/`. They run against the module that
   `zig build vendor-test-modules` installs; `zig build test` does that first. The suite also
   checks that every entry the module exports is declared, and every `# Native:` stand-in has
   an entry. Test without a display: a library that cannot run headless is not ready.
8. **Check the recipe.** `bash tools/check-vendor.sh` lists anything missing.
9. **Ship it** (when it should be in a release): set `.ships = true`, add its documentation
   page `docs/library/<name>.md` and its row in `docs/library/inventory.md`, write the website
   pages, and make the release workflow package `emerald-<name>` beside the binary. Until
   `.ships = true` the library is installed for tests only and no user program can name it.

## Trying it by hand

```bash
zig build
zig build vendor-test-modules
```

```bash
EMERALD_VENDOR_TEST=1 EMERALD_MODULE_PATH=zig-out/vendor-test-modules zig-out/bin/emerald run program.em
```

`EMERALD_VENDOR_TEST` lets a program name a library that does not ship yet.
`EMERALD_MODULE_PATH` lists directories to search for modules (separated by `:`, or `;` on
Windows). After it, Emerald looks in `lib` beside the executable and in `../lib`.

## What to expect at run time

- A module loads on the first call into it. If it cannot, the program stops with
  "`Name` is not available here" and a line that says what to try.
- The REPL does not load vendor libraries yet: a name that belongs to one is unknown there.
- On Linux the `emerald` executable links glibc (built for 2.28), so the system loader can
  load a module that has its own dependencies. A static or musl build loads no module and says
  so.
- A native runs on whichever task holds the interpreter, one at a time. A library with a rule
  about threads, as a window system has, checks it in its declarations.
