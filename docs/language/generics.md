# Generics

You have used generics since your first list. `List[Int]` and `List[String]` are one kind of
collection holding two kinds of item, and `Int` and `String` in the brackets say which. A
generic declaration of your own works the same way: write it once, and each use says what it
holds. Rewrite context 11.3 is the specification; run
[`examples/generics.em`](../../examples/generics.em) for everything below.

## A type that holds anything

Put names in brackets after a struct's, class's, or enum's name. Inside its braces each name is
a type:

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
```

A use writes its types in the same brackets, `Grid[String]`, wherever a type is written. You
never write them where you build a value: `Grid(9, ".")` is a `Grid[String]` because `"."` is a
`String`, and `const counts: Grid[Int] = Grid(4, 0)` is a `Grid[Int]` because of where it goes.
When neither says, Emerald asks you to write the type where the value is kept. A `Grid[Int]`
is not a `Grid[Float]`, but whole numbers given to a `Grid[Float]` become Floats, as they do in
a `List[Float]`.

`Item` could be any type, so inside `Grid` you can store it, pass it, return it, keep it in a
collection, and print it, and nothing more: no `==`, no `<`, no members. That is what lets
`Grid` promise to work for every type. A type in brackets is never optional (`Grid[Int?]`):
optionals do not nest, and `Grid` may already use `Item?` itself.

A type-level member, such as `func Grid.empty()`, belongs to `Grid` as a whole rather than to
one `Grid[Int]`, so it cannot use `Item`; give it a type of its own, as below.

## A function that works for anything

Functions and methods take types in brackets too. Each call works them out from what it is
given, and from where its result goes:

```emerald
func first_or[Item](items: List[Item], fallback: Item): Item {
    return if items.empty?() then fallback else items[0]
}

first_or([3, 4], 0)          # an Int
first_or([], "none")         # a String: `[]` says nothing, so "none" decides
```

A block's result counts too, so a method like `func mapped[Result](change: func(Item):
Result): Grid[Result]` makes `grid.mapped { cell => cell.count }` a `Grid[Int]`. To keep a generic
function as a value, give it a function type that says its types:
`const pick: func(List[Int], Int): Int = first_or`.

## Asking for more: `with`

To compare, order, or look up `Item`, require a trait that promises it:

```emerald
func largest[Item with Ordered](items: List[Item]): Item? {
    if items.empty?() {
        return nothing
    }
    var best = items[0]
    for item in items {
        best = item if item > best
    }
    return best
}
```

`with Ordered` lets the body use `<` and the List methods that sort or choose, and every type
given for `Item` must adopt `Ordered`. `with Equatable` allows `==` and `contains?`;
`with Hashable` makes `Item` a dictionary key or set member; `with Textual` gives it
`to_string()`. `Int`, `Float`, and `String` count as adopting all four (`Bool` all but
`Ordered`), and each has `compare`, `equals`, and `hash` methods for the purpose. Your own
traits work the same way: the body may call the trait's methods. One trait per type
parameter; to need two, write a trait that builds on both and require that one.

## Enums

An enum's choices can hold its types:

```emerald
enum Chain[Item] {
    end
    link(item: Item, rest: Chain[Item])
}

const numbers = Chain.link(1, Chain.link(2, Chain.end))   # a Chain[Int]
const empty: Chain[String] = Chain.end
```

A choice that holds nothing of a type, like `Chain.end`, fits a `Chain` of any type. A `case`
match names the data at the matched value's types.

## What Emerald leaves out

There are no wildcards and no variance: a `Grid[Int]` is never used as a `Grid[Float]`. A type
is never written at a call, never used as a value (`Item()` or `x is Item`), and never
reflected on; `is Grid[Int]` cannot be tested, since the types in brackets are not kept while
the program runs. Traits do not take type parameters, and a generic class does not extend or
get extended. These are deliberate: each would make generics larger than the problems they
solve here.
