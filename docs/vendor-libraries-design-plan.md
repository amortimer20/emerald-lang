# Vendor libraries and raylib: design plan

Status: proposed, 2026-11-06. Nothing here is accepted until the user accepts or changes the
decisions below. This is roadmap item 11 (handoff), written after Odin's `vendor:` collection
and the user's request that the way a vendor library is added be **reproducible for every
library the user brings in later**. So the plan has two parts: a general recipe (what every
vendor library is, and how one is added), and raylib as the first library built with it. Where
the two pull apart, the recipe wins, and raylib's slice 1 is where the recipe gets tested.

The executor makes the remaining judgement calls within a slice and records each under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## What a vendor library is

A **vendor library** is a native library, written in C or Zig by someone else, that ships with
Emerald behind an Emerald-shaped API (rewrite-context 14.4, 15.6, 24). It is not a package:
there is no package manager and none is planned, copied libraries stay pure Emerald, and the
platform family is the one channel for native code. Three things make up one:

1. **The upstream source,** pinned to an exact version and hash, never fetched at run time.
2. **A native glue file in Zig** that calls the upstream C API and exposes a small positional
   surface (integers, floats, text, bytes, and opaque handles).
3. **An Emerald declaration file (`.em`)** that gives the beginner-facing API: named
   arguments, enums, structs, optionals, doc comments, and Emerald errors, written over the
   positional surface the way `Stopwatch.start` is written over `Stopwatch._ticks`.

Everything the beginner sees is in (3). Everything C-shaped stays in (2). That split is the
whole reason to curate rather than bind, and it is what the recipe repeats.

## What beginner programs need

The API is judged by these programs. They are sketches: the exact names are decision 5.

```text
# A ball that bounces, and text that stays put.
struct Ball {
    var x: Float
    var y: Float
    var dx: Float
    var dy: Float
}

var ball = Ball(100.0, 100.0, 3.0, 2.0)

Graphics.run("Bounce", width: 640, height: 480) { screen =>
    ball.x += ball.dx
    ball.y += ball.dy
    if ball.x < 0.0 or ball.x > 640.0 { ball.dx = -ball.dx }
    if ball.y < 0.0 or ball.y > 480.0 { ball.dy = -ball.dy }

    screen.clear(Graphics.Color.black)
    screen.circle(ball.x, ball.y, radius: 12.0, color: Graphics.Color.yellow)
    screen.text("Close the window to quit", x: 10, y: 10, color: Graphics.Color.white)
}
```

```text
# A sound and a sprite, loaded once and used every frame.
const hit = Audio.load("hit.wav")
const ship = Graphics.load_image("ship.png")

Graphics.run("Shooter", width: 800, height: 600) { screen =>
    if screen.pressed?(Graphics.Key.space) { hit.play() }
    screen.image(ship, x: 400, y: 500)
}
```

What these need that Emerald does not have today: a block that runs once per frame until the
window closes, a native handle that owns a window, an image or a sound, and an error a
beginner can read when a file is missing or a window cannot open.

## Principles

1. **Emerald-shaped, not C-shaped** (principles 1 and 8). No C names, no null returns, no
   integer error codes, no `Vector2` that is really two floats, no flags ORed together.
2. **The base `emerald` stays what it is.** One file, no runtime dependency beyond the
   operating system's C library, runs on a server with no display. A vendor library must not
   change that for the beginner who never draws.
3. **Nothing downloads at build or run time** beyond the one pinned source fetch a contributor
   makes. A school machine needs no network.
4. **Every library is testable without a screen,** so CI proves the glue and the API on every
   push, and a human checks the pixels once per release.
5. **One recipe.** A second library should be a copy of the first one's folder with the names
   changed, not a new design.

## Verified constraints (checked against source and a probe, 2026-11-06)

- **raylib 6.2** is the current release (tags `6.0` and `6.2`; its `build.zig.zon` says
  minimum Zig **0.17.0**, the version Emerald is pinned to). License: zlib, which asks only
  that the notice travel with the source: one entry in THIRD_PARTY_NOTICES.md. It has its own
  `build.zig`, so Zig builds it with no CMake or make.
- **Probe on this Windows machine, Zig 0.17.0, ReleaseSafe:** raylib built with its default
  GLFW backend (34 seconds, a 7.7 MB static library with debug information) and with its own
  `win32` backend (18 seconds, 6.9 MB). Its `memory` backend, a software renderer that would
  give a headless target, failed to compile: `rlsw.h` is built as C99 and includes itself by
  a path that breaks on Windows. That is raylib's build, not a wall; slice 0 decides whether
  our own build file fixes it.
- **Linux is the hard platform.** Cross-building for `x86_64-linux-gnu` stops at "unable to
  find dynamic system library GL / X11 / Xrandr / Xinerama / Xi": raylib links the X11 and GL
  libraries by name. A binary built that way fails to start on a machine without them, which
  is every server and most minimal containers. Linking raylib *into* `emerald` would break
  principle 2 for Linux.
- **macOS** builds need Apple's frameworks (raylib's `build.zig.zon` fetches
  `xcode_frameworks` lazily); the release workflow already builds on a macOS runner, which has
  them. **WebAssembly** is raylib's other target and is the playground's concern (roadmap
  item 6, after 1.0), not this plan's.
- **Execution is one thread at a time.** Tasks are OS threads that pass a baton
  (concurrency plan), and windowing libraries insist on the thread that created the window;
  macOS insists on the main thread. So graphics calls belong to the main program only.
- **How natives are wired today.** The prelude (`src/prelude.em`) declares the API in Emerald
  with stub bodies; the interpreter answers a native by comparing the declaration's key
  against a chain of strings (`Console::_color` and the rest in `Interpreter.zig`); the checker
  types a few special calls by hand; `src/builtins.json` carries editor signatures. The prelude
  is parsed when Emerald is built and loaded for **every** run, so putting raylib's API in it
  would add startup cost for programs that never draw. A string chain per native call is also
  too slow for a frame loop that makes thousands of calls a second.
- **Current speed.** `benchmarks/baseline.md`: `fib` 0.31 s and `nbody` 0.47 s, startup
  included, so the interpreter is a tree walker. A 2D beginner game makes perhaps a few
  thousand native calls and a few hundred value updates a frame. Whether that holds 60 frames
  a second is unmeasured; slice 0 measures it.

## The recipe: what every vendor library contains

A vendor library `<name>` is the folder `vendor/<name>/` plus entries elsewhere. The recipe is
the list, and `tools/check-vendor.sh` (slice 1) fails CI when any item is missing.

| Item | Where | What it holds |
| --- | --- | --- |
| Record | `vendor/<name>/README.md` | Upstream URL, exact version and hash, license, why chosen, what is exposed, what is left out and why, the build options used |
| Pin | `build.zig.zon` | A lazy dependency with URL and hash, so a plain `zig build` fetches nothing |
| Build | `vendor/<name>/build.zig` | One function that builds the upstream source and the glue into the native module |
| Glue | `vendor/<name>/native.zig` | The positional surface, one Zig function per native, each checking its arguments and turning every failure into an error text |
| Declarations | `vendor/<name>/<name>.em` | The Emerald API, doc comments included |
| Cases | `conformance/vendor/<name>/` | `.em` programs and `.expected` output, run against the headless backend |
| Notice | `THIRD_PARTY_NOTICES.md` | The upstream license text |
| Docs | `docs/library/<name>.md`, inventory row, website pages | Same as every library family |
| Editor | `src/builtins.json` | Summaries for hover and signature help, covered by the same parity test |
| Release | `.github/workflows/release.yml` | The module in each archive, listed in `SHA256SUMS` |

Admission, for the user to apply to any future library: a license that lets Emerald ship it
(MIT, zlib, BSD, public domain; not GPL, which would change Emerald's own terms); source that
Zig builds without installing anything; no runtime dependency beyond the operating system; a
small enough surface to curate; and a way to run it headless. A library that fails one is a
conversation, not an exception.

## Decisions

Each carries a recommendation. The alternatives are kept for the record.

1. **Vendor source is pinned in `build.zig.zon` as a lazy dependency (recommended).** A normal
   `zig build` and `zig build test` fetch nothing and see no raylib; building the module asks
   for it, and the hash makes it reproducible. Alternative: copy raylib's source into the
   repository, like the Unicode tables. That removes the one fetch but adds 15 MB of C and a
   review burden on every upgrade.

2. **Each vendor library builds as its own dynamic module loaded on first use (recommended),**
   not linked into `emerald`. The release archive carries `lib/emerald-raylib.{so,dylib,dll}`
   beside the binary; the install scripts already extract the whole archive. A program that
   never names `Graphics` never loads it, so `emerald` is the same size and the same
   dependency-free binary for everyone (principle 2). If the module is missing or its system
   libraries are, the program stops with: "`Graphics` is not available here. This Emerald was
   installed without it, or this machine has no display libraries." The module speaks a small
   C ABI (decision 3), so the recipe does not depend on raylib. The compiler (item 12)
   links the same module statically into the programs it builds. Alternative: link it into
   `emerald`, which keeps one file but breaks headless Linux and grows every download by
   several megabytes; only worth it if slice 0 shows the X11 and GL libraries can be loaded
   late on every platform, which GLFW can do and raylib's build does not currently ask for.

3. **The native boundary is positional and small (recommended).** The module exports one
   function, `emerald_module(host)`, that returns a table of natives. A native takes and
   returns `Nothing`, `Bool`, `Int`, `Float`, `String`, or `Bytes`, and may fail with an error
   text. An opaque resource (a window, an image, a sound) is an `Int` handle the module owns;
   the Emerald side wraps it in a struct with a private `_id`, the way `Channel` does. Bulk
   data (many points, a pixel buffer) travels as `Bytes`. Nothing richer crosses: no callbacks
   from C into Emerald, no pointers, no lists. The interpreter resolves each native once, at
   the first call from a call site, to a function pointer, so a call after that costs a
   pointer call, not a string comparison. Alternative: let the glue read and build interpreter
   values directly. That is faster to write and welds every module to the interpreter's
   internals, which the compiler will replace.

4. **Vendor declarations load only when named (recommended).** `Graphics`, `Audio` and
   `Game` are visible in every file without an import, like the built-ins, and a user
   declaration with the same name wins, as 14.2 already says. Their `.em` files are parsed
   only when a file mentions the name; the prelude and every other program pay nothing. This
   needs one resolver change (slice 1). Alternative: an explicit `import vendor.Graphics`
   line, which is new syntax, one more thing to teach, and no better for the beginner. A
   second alternative, putting the declarations in the prelude, taxes every run.

5. **The raylib family is three libraries, not one (recommended):** `Graphics` (window,
   frame loop, shapes, text, images and sprites, keyboard and mouse), `Audio` (sounds and
   music), and `Game` (small helpers a game keeps rewriting: a fixed timer, rectangle and
   circle overlap, a camera). They share one module and one handle table, because raylib has
   one window and one audio device, but they document, version, and test separately.
   `Gui`, raylib's immediate-mode widgets (raygui), and 3D are out of scope for the first
   pass; both are one more slice on the same recipe when the user wants them.

6. **The frame loop is a block (recommended):** `Graphics.run(title, width:, height:) { screen => ... }`
   runs the block once per frame until the window closes or the block calls `screen.close()`.
   It opens the window first and closes it last, even when the block raises, so a beginner
   cannot leave a window open or forget to begin and end drawing, and it is the same shape as
   `Tasks.run`. Escape does not close the window unless the program says so
   (`close_on_escape: true`); the default is the one thing that surprises nobody. Alternative:
   `while screen.open?() { ... }`, which is how raylib's own examples read and which hands the
   beginner a drawing-state bug (forgetting `end`) that the block cannot have.

7. **Coordinates and colors are plain values (recommended).** Positions are `Float`s, sizes
   are `Int` pixels, with the origin at the top left as every 2D library has it. `Graphics.Color`
   is a struct with named constants (`Graphics.Color.red`) and `Color.rgb(r, g, b)`; it is a
   struct nested in the namespace the way `Console.Color` is (14.3). Keys and mouse buttons are
   enums (`Graphics.Key.space`). Alternative: raylib's `Vector2` and `Rectangle`, which add two
   types to learn before the first circle.

8. **Errors are Emerald errors (recommended).** `GraphicsError` for a window that will not
   open, an image that will not load, a handle used after it was closed; `AudioError` likewise;
   all extend `Error`, name the file or the call, and say what to try ("`ship.png` is not
   there. Is it in the same folder as the program?"). The module returns error texts and the
   wrapper in the `.em` file raises; raylib's own console logging is turned off, so no C text
   reaches a student's terminal.

9. **Graphics belongs to the main program (recommended).** A call from inside a task raises
   `GraphicsError`: "Graphics can only be used by the main program, not inside a task."
   A beginner game that wants concurrency passes messages to the main loop over a `Channel`.
   Alternative: marshal every call to the main thread, which hides a rule that exists for a
   reason and adds latency to every call.

10. **Interpreter first, with a measured gate (recommended).** Slice 0 runs a prototype: a
    window with 2,000 shapes drawn and 500 entities updated per frame, in the interpreter. If
    it holds 60 frames a second on the three release machines, raylib is built into the
    interpreter now, and the compiler later links the same module. If it does not, the
    library waits for item 12 and slices 0 and 1 still stand, because the recipe and the module
    interface do not depend on the engine that calls them. This is the question the handoff
    left open ("interpreter or compiler first"); the gate answers it with a number.

11. **Headless testing is a recorded command log (recommended).** The glue sits above raylib,
    so it has a `headless` mode (`EMERALD_GRAPHICS=headless`, and always on under `zig build
    test`) that never opens a window: every draw call appends a line to a log the program can
    read with `Graphics.recorded()`, and input comes from a script. Conformance cases assert
    the log, so CI proves the API, the argument checks, the errors, and the handle lifetimes on
    every platform with no display. What it cannot prove is that raylib draws a circle, so
    each release gets one manual pass on Windows, macOS, and Linux with a checklist, plus one
    Linux CI job that opens a real window under a virtual display (Xvfb) and draws one frame.
    Alternative: raylib's `memory` backend, which renders pixels in software and would let CI
    compare images, but it did not build in the probe and tests raylib more than Emerald.

12. **The API is experimental until 1.0 and says so (recommended).** The compatibility
    promise starts at 1.0 (item 13), and the first version of a drawing API is the one
    most likely to be wrong. The pages carry a note ("This library may change before 1.0"),
    and the family is frozen with the language. Alternative: promise stability from the first
    release, which is brave and probably regretted.

13. **A test-only library proves the recipe (recommended).** `vendor/selftest/` is a dozen
    lines of C and a `.em` file that exercise everything in decision 3: each value type, an
    error, a handle that must be closed, bytes in and out. It builds only under `zig build
    test`, never ships, and runs through the same loader, resolver change, and checks as
    raylib. If the recipe breaks for the next library, this is where it breaks first. A copy
    of it with the names blanked is `vendor/_template`, the folder to copy for the next
    library.

## Slices

Each slice is a branch and a pull request, built the usual way: one commit per change,
`/code-review` at high effort, handoff and journal updated, the user merges.

**Slice 0: a spike, no merge.** On a branch, answer the questions this plan could not: does
raylib build as a dynamic module on Linux, macOS, and Windows from the release workflow (X11
and GL loaded late or linked, and what the system needs); can the interpreter call into it;
the frame-rate gate of decision 10; the size of each module; whether the `memory` backend can
be made to build. The deliverable is a short report appended to this plan and a go or no-go on
decisions 2 and 10. Nothing from the branch merges.

**Slice 1: the mechanism.** The module ABI and loader, the per-call-site native cache, the
resolver's load-on-name, the `selftest` library with its conformance cases, `vendor/_template`,
`tools/check-vendor.sh`, and `docs/vendor-libraries.md`, the recipe as a how-to for the next
library. No raylib yet. Done when a second test library is added by following the how-to alone.

**Slice 2: `Graphics`, windows and shapes.** The module's window, the frame loop, clear,
shapes, text, keyboard and mouse; `Graphics.Color`, `Graphics.Key`; the headless log; docs,
website, inventory, examples; the release workflow carries the module. Done when the bounce
program above runs on all three systems and in the conformance suite.

**Slice 3: images and sprites.** Loading, drawing, scaling, and rotating images; sprite sheets;
text with a loaded font; the file-missing errors.

**Slice 4: `Audio`.** Sounds and music, the audio device's lifetime, volume, and the
no-device case (a laptop with no speakers must not crash a program).

**Slice 5: `Game`.** The small helpers, written after real programs show which ones are
needed. May be dropped.

Later, on the same recipe and with the user's go: `Gui` (raygui), 3D, and further libraries.

## Validation

- Each slice: `zig build test -j1`, the doc-example check, and the new conformance cases, run
  headless.
- Slice 1 additionally: add a second test library once by following only the how-to, and fix
  the how-to wherever it was wrong.
- Slice 2 onward, each release: the manual pass on three systems from a checklist kept beside
  the release notes, and the Xvfb job.
- The base binary: `emerald --version` and a hello world run on a Linux container with no X11
  or GL installed, in the release workflow, to keep principle 2 true.

## Out of scope

WebAssembly and the playground (item 6, after 1.0); Android, Raspberry Pi's DRM backend, and
other raylib platforms; 3D, shaders, and raygui in the first pass; networked games; a
package manager or any way for a user to add a native library to their own installation (the
recipe is for Emerald's maintainers, 14.4); and any change to the language itself beyond
resolver loading and the frame-loop block, which is an ordinary function with a block.

## Questions for the user

None blocks accepting the plan. The two with the most weight are decision 2 (a separate
module per library rather than one bigger binary) and decision 10 (whether a frame-rate
gate may send the library to the compiler's time). Both have a spike to settle them before any
code merges.
