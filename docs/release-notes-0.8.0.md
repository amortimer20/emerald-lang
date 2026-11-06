Emerald 0.8.0 lets you write a type or a function once for every kind of value it holds, and lets an enum's choices carry data. Both come with the plain-words errors, editor help, and guide pages the rest of the language has. It also follows a review of the whole language against a corpus of real beginner mistakes: errors now name what you wrote and what Emerald writes instead, five new warnings catch mistakes that used to pass silently, and about thirty wrong answers and crashes are fixed.

## Install

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1 | iex
```

macOS (Apple silicon, macOS 15 or later) and Linux (x86-64):

```bash
curl -fsSL https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.sh | sh
```

If you installed an earlier version with these scripts, running the command again updates it. Mise users can run `mise use -g "github:amortimer20/emerald-lang@latest"`. For the editor features below, also install the Emerald extension for Visual Studio Code, version 0.3.0 or newer.

## Generics

You have used generics since your first `List[Int]`. Now your own types and functions can work the same way:

```emerald
class Grid[Item] {
    var _cells: List[Item] = []

    constructor(count: Int, fill: Item) {
        for _ in 0..<count {
            self._cells.append(fill)
        }
    }

    func get(index: Int): Item {
        return self._cells[index]
    }
}

const board = Grid(9, ".")                 # a Grid[String]
const counts: Grid[Int] = Grid(4, 0)
```

- **Types, functions, methods, and enums** take types in brackets: `struct Pair[First, Second]`, `func first_or[Item](items: List[Item], fallback: Item): Item`, `func mapped[Result](...)`, `enum Chain[Item]`.
- **You never write types at a call.** Emerald works them out from the arguments, from where the value goes, or from what a block gives back, and says so plainly when nothing tells it.
- **`with` asks for more.** `func largest[Item with Ordered](items: List[Item]): Item?` may use `<` and `sort`, and every type given for `Item` must have an order. `with Equatable` allows `==` and `contains?`, `with Hashable` allows dictionary keys and set members, and your own traits work the same way.
- **Whole numbers stay honest.** A `Grid[Float]` built with `0` holds `0.0`, as a `List[Float]` would.
- **Your editor knows them.** Hover, go to definition, find references, and rename work on type parameters, signatures show their brackets, and completion offers what a `with` trait promises.

The new guide page, *Generics*, starts from `List[Int]`, and `examples/generics.em` is a runnable tour. There are no wildcards or variance: a `Grid[Int]` is never used as a `Grid[Float]`.

## Enums that carry data

An enum's choices can carry their own data, and `case` names it:

```emerald
enum Download {
    waiting
    finished(path: String)
    failed(message: String)
}

func describe(download: Download): String {
    return case download {
        when Download.waiting then "Waiting"
        when Download.finished(path) then "Saved to #{path}"
        when Download.failed(message) then "Failed: #{message}"
    }
}
```

A choice is built like a struct, by position or by name. Values compare and print with their data, can be dictionary keys when every choice's data can be, and a `case` that misses a choice says which. JSON, CSV, and typed `Console.table` rows refuse an enum that carries data, since a choice's name cannot hold it; convert it first. `examples/enum-data.em` shows more.

## Retiring things with `@deprecated`

Mark a function, type, field, method, property, or enum choice with `@deprecated` and say what to use instead:

```emerald
@deprecated("Use `total` instead.")
func sum_all(items: List[Int]): Int {
    return total(items)
}
```

Every use then warns, with your message as the correction, and Visual Studio Code strikes it through. Code inside the deprecated declaration itself doesn't warn. Warnings still make `emerald check` exit with status 1.

## New methods

- `compare`, `equals`, and `hash` on `Int`, `Float`, and `String`, and `equals` and `hash` on `Bool`. They give exactly what `<`, `==`, and a dictionary already give, as methods, so a generic function can call them. `compare` answers `-1`, `0`, or `1`, and on a `Float` it raises for NaN, as `hash` does.

## New in the library

Twelve small additions a first program reaches for:

- **Text:** `["Ada", "Grace"].join(", ")` on a list of strings; `text.words()`, which splits on spaces without empty pieces; `letter?()`, `digit?()`, `whitespace?()`, `upper?()`, and `lower?()` on a string; and `97.to_character()`, which turns a code point back into a character, so a Caesar cipher can be finished.
- **Lists:** `index_of(item)`, `repeat(times)` (`[["."].repeat(3)].repeat(3)` is a safe grid, since lists are values), and `append_all(items)`.
- **Numbers:** `Math.max(a, b)` and `Math.min(a, b)` for any two values with an order, and `random_fraction()` (and `Random.next_fraction()`) for a number from `0.0` up to `1.0`.
- **The program's surroundings:** `Program.environment("API_KEY")` reads an environment variable, `print_error(...)` writes to standard error, and `Console.clear()` clears the terminal (and does nothing when output is redirected).

## Errors that say what to write

A mistake from another language now gets the Emerald spelling, using your own names:

- **Words from other languages:** `elif`, `def`, `let`, `switch`, `unless`, `foreach`, `new`, `except`, `i++`, `lives--`, `!`, `&&`, `===`, `<>`, a C-style `for`, `do ... while`, `//` and `/* */` comments, curly quotes, `{"Ava": 12}`, and other languages' lambdas each say what Emerald writes.
- **Other languages' built-ins:** `len(names)`, `int(text)`, `str(5)`, `True`, `null`, `console.log(x)`, `names.size()`, `text.toUpperCase()` and the like point to `names.count`, `text.to_int()`, `5.to_string()`, `true`, `nothing`, `print(x)`, and `text.upper()`.
- **Close spellings:** a name, a member, or a type that is one edit from one that exists gets "Did you mean ...?", but only when exactly one candidate is that close.
- **Helps that fix the program when followed:** text mixed with a number (`age + 1` where `age` came from `input`) offers `age.to_int() + 1`; a value that may be `nothing` offers `.or(0)`, a check, or `String?`; `"-" * 20` offers `"-".repeat(20)`; `else (x > 0)` offers `else if`; `class Dog(Animal)` offers `extends`; and a bare enum choice offers `Color.red`.
- **Better places and wording:** a missing `)` is reported where the `(` opens, a duplicate name says where the first one is, a misplaced `super(...)` is reported where it is written, and a `break` inside an `each { }` block explains that a block is not a loop.

## Warnings for silent mistakes

Five new warnings, each for a mistake that ran without complaint and never did what was meant:

- `name.trim()` or `scores.sort()` on a line of its own: the result is thrown away and the original is unchanged.
- `"Hello ${name}"` or `"Hello {name}"`: Emerald interpolates with `#{name}`.
- `print(greet("Ava"))` where `greet` gives back nothing: it prints `nothing`.
- `while true` with no `break`: the loop never ends. The warning points at the loop, not at the code after it.
- `return value` inside a block passed to `each`: it leaves only the block, not the function.

A call to the built-in `exit()` now ends its path like `raise` does, so code after it gets the "this code can never run" warning, and a function whose last statement is `exit(1)` no longer needs a `return`.

In the editor, hovering a method that overrides another, or satisfies a trait, now shows the documentation it inherits when it has none of its own.

## Fixes and care

- Wrong answers fixed:
  - `%` and `//` on Floats floor the way the guide says, so `(a // b) * b + a % b` is `a` again, and `x % infinity` is `NaN`.
  - `**` and `Math.power` are exact to the last digit for large exponents.
  - `round_to` uses the number as you read it, so `1.005.round_to(2)` is `1.01`, as `format` already gave.
  - `split` and `replace` keep your text's own characters instead of rewriting them.
  - A string inside a displayed list or dictionary escapes `#{` and control characters.
  - Inside a generic function, `x is Int` and `type_name` see the real type, not `T`.
  - `Csv.format` no longer loses a row holding one empty field.
  - `Path.join`, `parent` and `absolute` give `/` on every system, and on Windows the path functions also read `\`.
  - On Windows, text such as `print("é")` shows correctly in a console.
  - A time zone name in `TZ` now falls back to Emerald's built-in zones.
- Tasks: `exit(code)` inside a task ends the program with that code, a task cancelled before it first runs does not run, and a cancelled receiver keeps a message already handed to it.
- Crashes fixed: `group_by` with five or more items in a group, `check` on two declarations with the same name, an `assert` message with interpolation, writing to a closed pipe, and a handful of failed-allocation crashes and leaks. The editor no longer crashes on a very deep expression or a renamed declaration named like a built-in, and answers a request with bad parameters instead of waiting forever.
- The formatter drops a byte-order mark and the stray `\r` of a CRLF comment, and the editor's formatting agrees with `emerald format`.
- The text of every error message Emerald raises is now part of the language, so a program that reads `error.message` can rely on it.
- A set of a type declared later in the file, holding a list, was wrongly accepted. It is refused, as it always should have been.
- Renaming a struct field, an enum choice's data, or a parameter in the editor now also renames it where a call names it, as in `Point(x: 1)`. Renaming an enum choice's data was refused before.
- `Stack[Int]()` and similar now explain that types in brackets are written where a value is kept, never where it is built.

## Upgrading from 0.7.0

- **New warnings can newly fail `emerald check`**, since warnings make it exit with status 1. A program that used to pass may now be told about a discarded `name.trim()`, a `${name}` in a string, a `print` of a call that gives back nothing, a `return` in an `each` block, or a `while true` with no `break`. Each warning says what to change.
- **A `map_keys` that gives two entries the same key is now an error naming both keys**, instead of quietly dropping one.
- **`round_to` now rounds the number as written.** `1.005.round_to(2)` is `1.01`, as `format` already gave.
- **`%` and `//` on Floats follow the divisor's sign, and `x % infinity` is `NaN`.** `7.5 % -2.0` is `-0.5`.

- **Macs need macOS 15 or later.** Emerald is now built with Zig 0.17, whose Mac programs need macOS 15 Sequoia or later; every Mac with Apple silicon can run it. Intel Macs are not supported, as before. The installer checks both and says so.

- Brackets after a type, function, or method name are now real syntax rather than an error. No program that ran on 0.7.0 used them.
- A method of your own named `compare`, `equals`, or `hash` keeps its name and wins over the new built-in ones, as before.
- A set of a later-declared type that holds a list is now an error (see above).
- A function of your own named `print_error` or `random_fraction` still works and wins over the new built-in, but now gets a warning saying it hides one. Rename it, or write `Emerald.print_error` to reach the built-in.
