# Emerald — v0 prototype

An experimental tree-walking interpreter for Emerald. The language runs: classes,
traits, enums, structs, lists, dictionaries, sets, operator overloading, static typing
with flow-sensitive narrowing, and a checker that treats its own diagnostics as a
deliverable. `docs/design.html` is the specification, and the argument for every
decision in it.

## Getting started

```
bash tools/install-cli.sh          # once — puts `emerald` on your PATH

emerald new my_game                # one file, no config
emerald run my_game/main.em
emerald check my_game/main.em      # look for problems without running

emerald repl                       # try a line at a time
emerald test my_game               # run every @test function
emerald fmt my_game                # one formatting, no settings
emerald explain                    # explain the last error, with a worked example
```

`build`, `ship` and `add` are named in the design and not built — each says what it
needs if you run it. They wait on a code generator, which is Phase 2.

`emerald` rebuilds the compiler whenever a `.cs` file is newer than the binary, so you
never run a stale build and there is no separate build step to remember.

**In VS Code:** install the extension (below), then **Ctrl+Shift+B** runs whatever `.em`
file you are looking at. **Ctrl+Shift+P → Run Test Task** runs the golden suite. Errors
land in the Problems panel as clickable entries — Emerald's `file.em:line  message`
diagnostic format is exactly what VS Code's problem matcher wants.

`playground/` is scratch space and is not part of the test suite.

## Editor support

```
bash tools/vscode-emerald/install.sh
```

Then **Ctrl+Shift+P → Developer: Reload Window**. Syntax highlighting, comment toggling,
bracket matching, and snippets (`class`, `trait`, `struct`, `prop`, `for`, `each`,
`ifthen`, …). See `tools/vscode-emerald/README.md`.

Note that copying the folder into `~/.vscode/extensions` does **not** work — current
VS Code only loads extensions listed in its `extensions.json` manifest, so a dropped-in
folder is ignored without any error. The script packages a `.vsix` and installs it, which
updates that manifest. Re-run it after changing the grammar or snippets.

**Inline errors work.** On save, the extension runs `emerald check --json` and squiggles
what comes back — including problems in *other* files of the same project, since a broken
file two directories away still breaks the build.

It is not a language server: no completion, no hover, no go-to-definition. Squiggles cover
a whole line, because Emerald's diagnostics carry a line but not a column.

The command is configurable via `emerald.checkCommand` — it defaults to routing through
WSL, since Smart App Control blocks the interpreter on Windows. Set it to an empty string
to turn diagnostics off.

## Running directly

```
dotnet run --project src/Emerald -- run examples/tour/main.em
```

**On Windows, Smart App Control may block the built assembly** (`0x800711C7`). It is a
code-integrity policy, separate from Defender antivirus, so folder exclusions do not
affect it — it blocks unsigned, low-reputation binaries, and a freshly compiled
interpreter is exactly that. Building under WSL avoids it:

```
wsl -- bash -lc "cd /mnt/c/path/to/emerald-lang && bash tests/run.sh"
```

Builds there use `-p:UseAppHost=false`, because the native launcher cannot be made
executable on an NTFS mount; the DLL is invoked directly instead.

## Tests

```
./tests/run.sh              # golden tests — everything
./tests/run.sh lists        # cases matching a name
BLESS=1 ./tests/run.sh      # rewrite .expected files from current output

./tests/examples.sh         # smoke-run every example project
./tests/exitcheck.sh        # process exit codes, which the golden suite cannot see
./tests/checkcheck.sh       # emerald check, human and --json output
./tests/newcheck.sh         # emerald new
./tests/fmtcheck.sh         # emerald fmt — a file afterwards, not a program's output
./tests/explaincheck.sh     # emerald explain, and the topic an error leaves behind
./tests/testcheck.sh        # emerald test, and the commands that are not built yet
./tests/replcheck.sh        # emerald repl — a session, not a file
./tests/tourcheck.sh        # docs/tour.html — every snippet on the page, run
./tests/gamecheck.sh        # examples/games/ — rules tested, and each game played through
./tests/grammarcheck.sh     # docs/design.html §9 — the grammar, against the compiler
```

The last seven test *commands* rather than programs, which is why they are not golden
cases: what they produce is a rewritten file, an exit code, or a state file.

Golden tests: each `tests/cases/*.em` runs and its combined output is diffed against a
`.expected` file. Deliberately end-to-end rather than unit tests against `Scanner` or
`Parser` internals — those would need rewriting every time the compiler is restructured,
while these only assert what a program *does*.

**Diagnostic text is under test too.** The error messages are a design deliverable, not
an implementation detail, so a case exists for each one. Changing a message is fine;
changing it *by accident* is what the suite prevents.

`BLESS=1` after a deliberate change, then read the diff before committing it.

## Where things are

| File | Job |
|---|---|
| `Token.cs` | what a token is |
| `Scanner.cs` | source text → tokens, plus the newline rules |
| `Ast.cs` | the node types |
| `Parser.cs` | tokens → tree (implements §9 of the design doc) |
| `Types.cs` | what a type is, and the built-in signatures |
| `Checker.cs` | tree → types, including flow-sensitive narrowing |
| `Environment.cs` | variable scopes |
| `Interpreter.cs` | tree → behavior |
| `Builtins.cs` | Kernel functions and the sprinkles |
| `Program.cs` | the CLI and diagnostic formatting |

The pipeline is `Scanner → Parser → Checker → Interpreter`. Each stage only knows about
the one before it, and the checker and interpreter walk the *same* tree — one computing
types, the other values. To add a feature you generally touch four places: a token (if
it needs new syntax), a node type, a checking case, and an evaluation case.

## What v0 does

`var` / `const`, arithmetic and comparison, `and` / `or` / `not`, string interpolation,
ranges, `if` / `else if` / `else`, the `if … then … else` expression, modifier-`if`,
`while`, `for … in`, `func` with `return`, lambdas (braced and arrow), trailing lambdas,
compound assignment, and the Int / Float / String / Range sprinkles.

## Type checking

Real, and it runs before the interpreter ever sees the program. It catches unknown
variables, const reassignment, annotation mismatches, bad operand types, mismatched
`if`/`then` branches, unknown methods (with a "did you mean"), and reaching through a
value that might be nothing.

Flow-sensitive narrowing works — see `examples/narrowing/`:

```
var maybe = "42".to_int_maybe()   # Int?

print(maybe.abs)                  # error: might not exist

if maybe != nothing {
    print(maybe.abs)              # fine — narrowed to Int here
}
```

## Arrays

`Array<T>` is the one generic type — the compiler owns it, and users can't declare
generics of their own. Block parameters are inferred from the element type:

```
var numbers = [5, 3, 8]

numbers.map { x => x * 2 }        # x is Int, so x.upper is a compile error
numbers.filter { x => x.even? }
numbers.find { x => x > 100 }     # Int? — the checker makes you handle the miss
```

`find`, `first`, `last`, `min`, and `max` all return `T?`, because they can miss.

## Classes

Fields, `constructor`, methods, `self`, and single inheritance — with dynamic dispatch,
so a base-class method calling `self.speak()` reaches the subclass's override. Both
declaration forms work: a braced `class X { }`, or the block-free file form where the
`class` line is followed by the rest of the file as its body.

```
class Dog extends Animal {
    func speak(): String {
        return "Woof"
    }
}

var rex = Dog("Rex")        # no `new`
print(rex.introduce())
```

`self` is deliberately *not* a keyword — it is an ordinary binding introduced into a
method's scope, so `self.name` is plain member access and needs no special handling
anywhere in the parser, checker, or interpreter.

## Traits

A trait requires members with `abstract func` and provides them with an ordinary `func`.
An interface is simply a trait that provides nothing — there is no separate feature.

```
trait Swimmer {
    abstract func stamina(): Int      # required of you
    func swim(): String {             # provided to you
        return "swimming for #{self.stamina()} minutes"
    }
}

class Dog extends Animal with Swimmer {
    func stamina(): Int { return 30 }
}
```

Traits hold no state — a field in a trait is an error, with the fix suggested. A type
with any unimplemented member is abstract and cannot be created, which is inferred
rather than declared.

Trait conformance resolves lazily, so a trait may be declared *after* the class that
mixes it in. Order within a file never matters.

## Statics, properties, and structs

```
class Circle {
    static const PI = 3.14159
    static var made: Int = 0

    var radius: Float

    var area: Float {
        get { return Circle.PI * self.radius * self.radius }
    }

    var diameter: Float {
        get { return self.radius * 2.0 }
        set { self.radius = value / 2.0 }
    }

    static func unit(): Circle { return Circle(1.0) }
}
```

A property is a `var` with a body — callers cannot tell it from a stored field, so
promoting one to the other never breaks calling code. A setter sees `value`.

**Structs are immutable.** Only a struct's own constructor may write its fields, which
is what makes C#'s `transform.position.x = 5` unwritable here rather than merely
discouraged. Value-copy semantics are unimplemented and unobservable: copying an
immutable value is indistinguishable from sharing it.

## Projects

**A project is a directory.** Every `.em` file beside the entry file is part of it, and
no file writes an import — see `examples/pets/`:

```
pets/
  main.em          # runs
  animal.em        # class Animal        (block-free)
  dog.em           # class Dog extends Animal
  cat.em           # class Cat extends Animal
  sound_utils.em   # no class line → a module
```

A file that declares a type contributes it directly, visible everywhere by name. A file
that declares none is a **module**: it has no instances, so its members become static and
are reached as `SoundUtils.loudly(...)`.

This is what makes the block-free class form useful — one type per file, no braces, no
nesting level, and nothing to import.

## What v0 does not do

- **Built-in argument types are unchecked.** The checker knows what a method returns,
  not what it accepts.
- **Projects are flat.** Directory-as-namespace (`Shapes.Dog`) is designed but not built,
  so two same-named types in different folders will collide.
- **No external packages.** `import raylib` does not exist yet.
- **No macros or attributes.**
- **No modules or imports.** One file at a time.
- **No macros or attributes.**

Both v0 gaps found on the first run are fixed: runtime errors now carry a line and a
source excerpt, and `if x = 5 { }` explains `=` versus `==` rather than reporting a
missing brace.

## Examples

- `examples/mad_lib/` — the §4 sample
- `examples/guessing_game/` — the §4 sample
- `examples/tour/` — everything v0 supports, in one file
- `examples/games/` — Hangman, Wordle and tic-tac-toe, the first real programs
