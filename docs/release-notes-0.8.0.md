Draft for the next release, written ahead of it. Revise before tagging if anything below changes, and drop this line.

Emerald 0.8.0 lets you write a type or a function once for every kind of value it holds, and lets an enum's choices carry data. Both come with the plain-words errors, editor help, and guide pages the rest of the language has.

## Install

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1 | iex
```

macOS (Apple silicon) and Linux (x86-64):

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

## New methods

- `compare`, `equals`, and `hash` on `Int`, `Float`, and `String`, and `equals` and `hash` on `Bool`. They give exactly what `<`, `==`, and a dictionary already give, as methods, so a generic function can call them. `compare` answers `-1`, `0`, or `1`, and on a `Float` it raises for NaN, as `hash` does.

## Fixes and care

- A set of a type declared later in the file, holding a list, was wrongly accepted. It is refused, as it always should have been.
- `Stack[Int]()` and similar now explain that types in brackets are written where a value is kept, never where it is built.

## Upgrading from 0.7.0

- Brackets after a type, function, or method name are now real syntax rather than an error. No program that ran on 0.7.0 used them.
- A method of your own named `compare`, `equals`, or `hash` keeps its name and wins over the new built-in ones, as before.
- A set of a later-declared type that holds a list is now an error (see above).
