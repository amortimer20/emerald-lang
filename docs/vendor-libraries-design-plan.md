# Vendor libraries and raylib: design plan

Status: accepted by the user, 2026-11-06 (all decisions as recommended, with the spike's changes to 2 and
11); slice 1 merged (PR #70). **Revision 1** (below, proposed the same day at the user's request: Raylib by name,
the whole surface including raygui) replaces several decisions and the slices; the user accepted it as
recommended, questions D to F included, the same day. Written as a proposal the same day. Slice 0 (the spike) has run; its report is below, and it changed
decisions 2 and 11 and tightened 1 and 10. Questions A and B are answered and C is agreed, with its measurements pending (see "Slice 0
report"). Do not reopen an accepted decision. This is roadmap item 11 (handoff), written after Odin's `vendor:` collection
and the user's request that the way a vendor library is added be **reproducible for every
library the user brings in later**. So the plan has two parts: a general recipe (what every
vendor library is, and how one is added), and raylib as the first library built with it. Where
the two pull apart, the recipe wins, and raylib's slice 1 is where the recipe gets tested.

The executor makes the remaining judgement calls within a slice and records each under that
slice's "Settled while building" note. At the start of each slice, reread `git status`, the
recent `git log`, and docs/handoff.md.

## Revision 1: Raylib by name, and the whole of it (2026-11-06)

The user asked, after slice 1 merged, for two changes: the library keeps its own name
everywhere a reader sees it ("Raylib everywhere"), and Emerald gives **full access to
everything raylib has to offer, including raygui**. That reopens principle 1, decisions 3, 4,
5, 7 and 8, the admission rule, the slices, and the out-of-scope list. Revision 1's decisions,
R1 to R8 below, replace those where they conflict; each replaced passage below carries a note.
Everything else stands: the module mechanism slice 1 built, load-on-name, the frame block
(decision 6), main-thread only (9), the frame-rate gate (10) and question C, the software
backend (11), experimental until 1.0 (12). **Status: accepted by the user, 2026-11-06, as
recommended, with questions D, E and F answered as recommended.**

What "everything" counts, in the raylib 6.2 headers the spike fetched: 619 functions in
`raylib.h`, 146 in `raymath.h` (the vector and matrix math), and 163 in `rlgl.h` (raylib's
OpenGL layer), plus raygui's functions, structs, enums and constants. At that size the glue
and declarations cannot be written by hand and kept right, so the recipe gains a generator,
and the generator is what makes the next library reproducible too.

R1. **A vendor library is named after its upstream project, everywhere (the user's rule).**
For raylib: the folder `vendor/raylib/`, the module `emerald-raylib`, the namespace `Raylib`,
the error type `RaylibError`, the page `docs/library/raylib.md`. raygui draws through raylib's
window and state, so it is built into the same module, but it keeps its own name: a second
namespace, `Raygui`, with its own pin, notice, and section of the record (question D).
Replaces the names in decisions 4, 5 and 8, and the three-library split of decision 5
(`Graphics`, `Audio`, `Game`): there is one library, as there is one raylib.

R2. **The whole surface, with exceptions listed (recommended).** Every function, struct, enum
and named constant in `raylib.h`, `raymath.h`, `rlgl.h` and `raygui.h` at the pinned versions.
The record lists each exception with its reason. Expected exceptions: raw memory functions
(`MemAlloc`, `MemFree`, the `Unload...Data` functions that free a buffer the glue already
copied into Emerald), which have no meaning without pointers; and C callbacks
(`SetTraceLogCallback`, the file-data and text callbacks, audio stream callbacks and
processors), which need C to call into Emerald, a thing decision 3 rules out (question F).
Functions that repeat something Emerald already has (file reading, random numbers, text
formatting) are kept, because "everything" means a raylib program reads the same in Emerald.

R3. **The glue and declarations are generated (recommended).** A generator,
`tools/vendor-bind` (Zig, run by `zig build vendor-bind`), reads a library's API description
and writes `vendor/<name>/generated/native.zig` (the glue) and
`vendor/<name>/generated/<name>.em` (the declarations). Generated files are committed, so a
build needs neither the generator's input nor the upstream parser; a CI check regenerates them
and fails on a difference, the way the editor-signature parity test works. Two hand-written
files carry what no description holds: `vendor/<name>/bind.json`, the overrides (which calls
can fail and how to tell, which pointer parameters are outputs, which array goes with which
count, which structs are resources), and `vendor/<name>/<name>.em`, the hand-written layer
(R7). The description for raylib, raymath, rlgl and raygui comes from raylib's own header
parser (`rlparser`, in raylib's repository), whose JSON is committed with the pin; slice 2
verifies that it covers raygui, and writes the description by hand for anything it misses.
**For the next library**, the generator reads the same description format: a library with a
regular header gets an adapter or a hand-written description, then the same overrides file
and the same generator. Replaces "Glue: `native.zig`, one Zig function per native" in the
recipe table.

R4. **Names follow one mechanical rule (recommended),** so a reader can work out the Emerald
name of any function in raylib's cheatsheet:
- Functions in snake case: `DrawCircle` becomes `Raylib.draw_circle`. A leading `Is` becomes
  Emerald's trailing `?`: `IsKeyPressed` becomes `Raylib.key_pressed?`.
- raygui drops its `Gui` prefix, because the namespace says it: `GuiButton` becomes
  `Raygui.button`.
- A raymath function whose first parameter is the struct it names becomes a method:
  `Vector2Add(a, b)` becomes `a.add(b)`, `MatrixInvert(m)` becomes `m.invert()`.
- Structs keep raylib's names (`Raylib.Vector2`, `Raylib.Camera3D`, `Raylib.Rectangle`), with
  fields and parameters in snake case, and every parameter can be passed by name.
- Enums drop their shared prefix: `KEY_SPACE` becomes `Raylib.Key.space`, `FLAG_VSYNC_HINT`
  becomes `Raylib.ConfigFlags.vsync_hint`; raylib's color constants become
  `Raylib.Color.raywhite` and the rest.
- A name that collides with an Emerald keyword gets a trailing underscore, listed in the record.

The record carries the whole C-to-Emerald table, generated.

R5. **Richer values cross the boundary (recommended; widens decision 3).** Module ABI
version 2 adds three things, still with no pointers and no interpreter internals:
- **Records.** A value struct (`Vector2`, `Color`, `Rectangle`, `Matrix`, `Camera2D`, `Ray`,
  `BoundingBox`, and the rest) crosses as a list of scalar values in field order, nested
  structs flattened, and the Emerald side builds the struct.
- **Lists.** An array parameter (the points of a polygon, vertices) crosses as a list of
  records or scalars; the overrides pair it with its count parameter, which the Emerald
  signature drops. Pixel and sample buffers stay `Bytes`.
- **Outputs.** A pointer the C function writes through (`bool *active` in a raygui check box,
  `char *text` in a text box, `int *` scroll positions) becomes a returned value:
  `Raygui.check_box(bounds, text, checked)` gives back the new `Bool`, and a text box takes
  and gives back a `String`. A function with several outputs gives back a struct.

Resource structs, which own memory or GPU objects (`Image`, `Texture`, `RenderTexture`,
`Font`, `Mesh`, `Shader`, `Material`, `Model`, `ModelAnimation`, `Wave`, `Sound`, `Music`,
`AudioStream`), stay handles the module owns, wrapped in Emerald structs with a private `_id`,
as slice 1's `SelftestCounter` is. raylib's `Unload...` functions are their `unload()`;
anything still loaded when the program ends is freed by the module's shutdown. Their public
fields (a texture's width and height) are read through generated getters.

R6. **Failures are `RaylibError` (recommended; replaces decision 8's names).** Where raylib
signals failure (a resource that fails its `Is...Valid` check, a false result, an empty
handle), the overrides say so, and the generated wrapper raises `RaylibError` naming the call
or the file, with a help line. raylib's console logging is off unless the program turns it on
with `Raylib.set_trace_log_level`, which is part of the surface.

R7. **A hand-written layer stays on top (recommended).** `vendor/raylib/raylib.em` keeps
decision 6's frame block as `Raylib.run(title, width:, height:) { screen => ... }`: it opens
the window, begins and ends each frame, and closes the window even when the block raises.
Nothing hides the layer below: a program may call `Raylib.init_window`,
`Raylib.window_should_close?` and `Raylib.begin_drawing` itself, exactly as raylib's own
examples do. Decision 7's "no `Vector2`" is reversed, since raylib has one; the hand-written
layer adds forms that take plain `Float`s only where an example reads better for them.
Hand-written functions are few, and each is documented as Emerald's, not raylib's.

R8. **Testing at this size (recommended; extends decision 11).** Slice 1's agreement test
already proves every module entry has a declaration and the reverse. Added: the regenerate
check (R3); a generated case per pure function with a known answer from the C side (all of
raymath, and the color and text helpers); pixel-checksum cases per header section (shapes,
text, textures, 3D, raygui) on the software backend; and a set of raylib's own examples ported
to Emerald per slice, as acceptance. Whether the software backend draws 3D and raygui with one
checksum on all three systems is unverified; the slice that adds 3D checks it, and decision
11's command log is the fallback for any section where it does not.

Principle 1 now reads: **Emerald-shaped names, values and errors, over the complete surface.**
No null returns and no integer error codes, but raylib's own structs and functions are all
there, by a rule a reader can follow. The admission rule's "a small enough surface to curate"
now reads: **an API description a generator can read, with the exceptions listed.** The
out-of-scope list no longer holds 3D, shaders or raygui.

Revised slices (replacing slices 2 to 5 below). Each slice turns on more of raylib's headers in
the same generator, so most of a slice after the second is overrides, tests, examples and
docs, not new machinery. Each is one PR, as before.

- **Slice 2: the generator and raylib's core.** Module ABI version 2 (records, lists,
  outputs), `tools/vendor-bind` and the regenerate check, the raylib pin and module build (the
  window backend and the software backend), and from `raylib.h` the window, drawing, input and
  timing functions, shapes, default-font text, and the colors and enums they use;
  `Raylib.run`; the release workflow carries the module. Done when the bounce program runs on
  all three systems and in the conformance suite.
- **Slice 3: images, textures and fonts,** with the file-missing errors.
- **Slice 4: audio,** with the no-device case (a laptop with no speakers must not crash a
  program).
- **Slice 5: 3D and raymath:** models, meshes, materials, shaders, cameras, and the math
  methods.
- **Slice 6: rlgl,** raylib's OpenGL layer (question E).
- **Slice 7: Raygui:** the second pin, the `Raygui` namespace, styles.
- **Later:** callbacks (question F), and the next library on the same recipe.

The two sketch programs above become, under R4 and R7:

```text
Raylib.run("Bounce", width: 640, height: 480) { screen =>
    # ... the same updates ...
    Raylib.clear_background(Raylib.Color.black)
    Raylib.draw_circle(ball.x, ball.y, radius: 12.0, color: Raylib.Color.yellow)
    Raylib.draw_text("Close the window to quit", x: 10, y: 10, font_size: 20, color: Raylib.Color.white)
}
```

```text
Raylib.init_audio_device()
const hit = Raylib.load_sound("hit.wav")
const ship = Raylib.load_texture("ship.png")

Raylib.run("Shooter", width: 800, height: 600) { screen =>
    if Raylib.key_pressed?(Raylib.Key.space) { Raylib.play_sound(hit) }
    Raylib.draw_texture(ship, x: 400, y: 500, tint: Raylib.Color.white)
}
```

New questions for the user from revision 1:
- **D. Accepted: `Raygui`.** raygui's namespace. Recommended: `Raygui`, its own name, so a reader sees which
  project a call comes from (R1's rule). The alternative is `Raylib.Gui`.
- **E. Accepted: included, as slice 6.** rlgl: raylib's thin layer over OpenGL, for programs that outgrow raylib's drawing
  functions. It is part of "everything", and it comes last because it is the least
  beginner-facing and the hardest to test in the software backend. Recommended: include it, as
  slice 6.
- **F. Accepted: later, after slice 7.** Callbacks: C calling into Emerald (a log callback, an audio processor) needs the
  interpreter to be entered from a C stack, which decision 3 ruled out. Recommended: leave
  them out of slices 2 to 7 and decide when the rest is done; the record lists them.

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

1. **Emerald-shaped, not C-shaped** (principles 1 and 8; reworded by revision 1). No C names, no null returns, no
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
| Glue | `vendor/<name>/native.zig` (generated, per R3) | The positional surface, one Zig function per native, each checking its arguments and turning every failure into an error text |
| Declarations | `vendor/<name>/<name>.em` | The Emerald API, doc comments included |
| Cases | `conformance/vendor/<name>/` | `.em` programs and `.expected` output, run against the headless backend |
| Notice | `THIRD_PARTY_NOTICES.md` | The upstream license text |
| Docs | `docs/library/<name>.md`, inventory row, website pages | Same as every library family |
| Editor | `src/builtins.json` | Summaries for hover and signature help, covered by the same parity test |
| Release | `.github/workflows/release.yml` | The module in each archive, listed in `SHA256SUMS` |

Admission, for the user to apply to any future library: a license that lets Emerald ship it
(MIT, zlib, BSD, public domain; not GPL, which would change Emerald's own terms); source that
Zig builds without installing anything; no runtime dependency beyond the operating system; a
small enough surface to curate (now: an API description a generator can read, R2 and R3); and a way to run it headless. A library that fails one is a
conversation, not an exception.

## Decisions

Each carries a recommendation. The alternatives are kept for the record.

1. **Vendor source is pinned in `build.zig.zon` as a lazy dependency (recommended).** A normal
   `zig build` and `zig build test` fetch nothing and see no raylib; building the module asks
   for it, and the hash makes it reproducible. Alternative: copy raylib's source into the
   repository, like the Unicode tables. That removes the one fetch but adds 15 MB of C and a
   review burden on every upgrade.

2. **Each vendor library builds as its own dynamic module loaded on first use (recommended;
   the spike confirmed it works, with one cost on Linux, below),**
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

3. **The native boundary is positional and small (recommended; widened by R5).** The module exports one
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

4. **Vendor declarations load only when named (recommended; the names are now R1's).** `Graphics`, `Audio` and
   `Game` are visible in every file without an import, like the built-ins, and a user
   declaration with the same name wins, as 14.2 already says. Their `.em` files are parsed
   only when a file mentions the name; the prelude and every other program pay nothing. This
   needs one resolver change (slice 1). Alternative: an explicit `import vendor.Graphics`
   line, which is new syntax, one more thing to teach, and no better for the beginner. A
   second alternative, putting the declarations in the prelude, taxes every run.

5. **Replaced by R1 and R2.** The raylib family is three libraries, not one (recommended): `Graphics` (window,
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

7. **Replaced by R4, R5 and R7.** Coordinates and colors are plain values (recommended). Positions are `Float`s, sizes
   are `Int` pixels, with the origin at the top left as every 2D library has it. `Graphics.Color`
   is a struct with named constants (`Graphics.Color.red`) and `Color.rgb(r, g, b)`; it is a
   struct nested in the namespace the way `Console.Color` is (14.3). Keys and mouse buttons are
   enums (`Graphics.Key.space`). Alternative: raylib's `Vector2` and `Rectangle`, which add two
   types to learn before the first circle.

8. **Errors are Emerald errors (recommended; the names are now R6's).** `GraphicsError` for a window that will not
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

11. **Headless testing is raylib's software backend, compared by pixel checksum (recommended,
    changed by the spike).** The first draft recommended a recorded command log, because the
    software backend did not build in the probe. The spike built it with three small fixes and
    it drew **byte-identical pixels on Windows, macOS, and Linux** (one checksum, three
    systems), so CI can test real drawing with no display and no extra glue. The command log
    below stays as the fallback if input scripting or a future raylib breaks the software
    backend. The original recommendation, a recorded command log: the glue sits above raylib,
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

Slices 0 and 1 are done. Slices 2 to 5 below are replaced by revision 1's slices 2 to 7.

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

## Slice 0 report (2026-11-06)

The spike is the branch `claude/raylib-spike` (not for merge; delete it once this plan is
accepted). It builds raylib 6.2 into an eight-function C-ABI module, loads it from the
interpreter through a throwaway `Gfx` class, and ran on this Windows machine and, through a
workflow, on GitHub's Ubuntu, macOS, and Windows runners (run 42238784259). It answers the
plan's open questions:

**Can the interpreter call into a module?** Yes, on all three systems. Three things were
learned on the way:
- Zig 0.17's `std.DynLib` has **no Windows support**; the spike declares `LoadLibraryA` and
  `GetProcAddress` itself. The macOS path (`dlopen` through `std.DynLib`) works unchanged.
- On Linux, `std.DynLib` falls back to a pure-Zig ELF loader when the program does not link
  libc, and that loader **cannot load a module that has its own dependencies** (libc, libX11):
  the spike segfaulted at the first call. With `emerald` linked against glibc, the system's
  `dlopen` loads the module and it drew frames under a virtual display (Xvfb).
- Linking glibc makes the Linux `emerald` a dynamic executable that needs only `libc.so.6`.
  Built for `x86_64-linux-gnu.2.28`, it ran in `debian:10` and `ubuntu:20.04` containers with
  no X11 or GL installed, so principle 2 holds in spirit (no display libraries needed) but not
  in letter (the Linux binary is no longer fully static, and an Alpine or other musl system
  needs glibc compatibility). **This is question A for the user.**

**Frame rate (decision 10).** On this machine (16 cores, ReleaseSafe, vsync off, a window
open), updating 500 objects takes 1.1 ms a frame, and drawing 2,000 circles through the module
adds 10 ms for the loop and the calls, so **87 frames a second for 2,000 shapes and 500
entities, and 38 for 5,000 shapes**. In the 2,000-shape frame, about 3.2 ms is the
interpreter running the drawing loop itself and about 2.9 ms is the 2,000 module calls
including raylib's own drawing (roughly 1.5 microseconds a call). So the module boundary is
not the cost; the interpreter's loop is, and batching calls would help only the smaller part.
On GitHub's shared runners with raylib's software renderer, the draw-only case (2,000 shapes)
ran at 78 frames a second on Linux, 76 on Windows, and 58 on macOS. The gate (60 frames a
second on the three release machines) is **met on the one real machine measured and not
proven on a school-class laptop or a Mac**, which the spike had no access to. **This is
question C for the user.**

**Headless backend (decision 11).** raylib's `memory` platform builds with three fixes that
our own build file applies, none of them in raylib's code: compile as C11 (`-std=gnu11`),
add the build root to the include path (`rlsw.h` includes itself by a path relative to it),
and link `winmm` on Windows. It renders in software and, read back with `LoadImageFromScreen`,
gave the same checksum (`1779814050833076541`, FNV-1a over the pixels) for the same drawing
on all three systems, on every run. The module is 1.9 MB on Windows, 1.5 MB on macOS, and
7.0 MB on Linux (debug information included). **This is question B for the user.** Not
tried: scripting keyboard and mouse input into this backend; slice 2 settles it.

**Real windows in CI.** On GitHub's hosted Windows and macOS runners, opening a window
crashes (no display or GPU), so a real-window smoke test is possible only on Linux under
Xvfb, as decision 11 already says. The manual per-release pass stays.

**Sizes (ReleaseSafe, GLFW backend).** Windows module 2.1 MB, macOS 1.8 MB, Linux 7.6 MB
(unstripped). The macOS module depends only on system frameworks (AppKit, CoreGraphics, IOKit
and the like); the Linux module on libX11 and its dependencies, plus libc and libm.

**Build facts for the recipe.**
- raylib's `build.zig.zon` lists a lazy dependency, `xcode_frameworks`, fetched from
  `pkg.machengine.org`, a third party's host. A native macOS build asked for it anyway and
  panicked at configure time until the spike listed it in its own `build.zig.zon`. So a
  vendor library's pin must also list its dependencies' lazy dependencies, and a third-party
  host is a release risk worth a mirror or a copy if it ever fails.
- Linux needs the X11 and GL development packages to build the module (`libx11-dev`,
  `libgl1-mesa-dev`, `libxrandr-dev`, `libxinerama-dev`, `libxcursor-dev`, `libxi-dev`), and
  Xvfb with Mesa to run it. Zig 0.17 keeps fetched packages in the project's `zig-pkg/`
  folder, which the repository must ignore.
- Building the GLFW module takes 1.5 to 3 minutes per system, so the release workflow grows
  by that much per vendor library.

**What the spike did not settle.** A real-window run on macOS and on a weak machine; input
scripting in the software backend; whether the native-call cache matters (the spike's check
sits first in the dispatch chain, and a native placed later pays more string comparisons per
call); and what a Linux machine without the X11 libraries sees when it loads the module (it
links X11 by name, so the load fails with a missing-library error, which decision 2's message
must cover).

**Questions for the user from the spike.**
- **A. Accepted by the user, 2026-11-06: link glibc dynamically in the Linux `emerald`** (built for glibc 2.28 and later), so
  modules can load. The alternative keeps the Linux binary fully static and gives it no module
  loading: vendor libraries would live in a separate games executable on Linux, which breaks
  "one installation" there. The release workflow therefore builds the Linux binary for
  `x86_64-linux-gnu.2.28` with libc linked; slice 1 makes that change and adds the bare-container
  check to the release workflow. Windows and macOS are unchanged.
- **B. Accepted by the user, 2026-11-06: test drawing with the software backend and pixel checksums** instead of a recorded
  command log (decision 11 as amended). Recommended: yes.
- **C. Agreed by the user, 2026-11-06 (measurements pending): measure the frame rate on a Mac and on one slow machine** before slice 2. The
  spike's program is `spike/bench/frames.em`, run against the module built by
  `spike/raylib/build.zig`. Recommended: yes, ten minutes each; if either misses 60 frames a
  second at 2,000 shapes, the plan's fallback is the compiler.

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
other raylib platforms; C callbacks into Emerald (question F; 3D, shaders and raygui are now in, per revision 1); networked games; a
package manager or any way for a user to add a native library to their own installation (the
recipe is for Emerald's maintainers, 14.4); and any change to the language itself beyond
resolver loading and the frame-loop block, which is an ordinary function with a block.

## Questions for the user

None blocks accepting the plan. The two with the most weight are decision 2 (a separate
module per library rather than one bigger binary) and decision 10 (whether a frame-rate
gate may send the library to the compiler's time). Both have a spike to settle them before any
code merges.
