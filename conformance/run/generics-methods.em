# Section 11.3: a method with its own type, on a generic class and on an
# ordinary one, and a type-level function with its own type.
class Box[Item] {
    const value: Item

    func mapped[Result](change: func(Item): Result): Box[Result] {
        return Box(change(self.value))
    }

    func paired[Other](other: Other): (Item, Other) {
        return (self.value, other)
    }

    func Box.of[Value](value: Value): Box[Value] {
        return Box(value)
    }
}

const name = Box("Ava")
print(name.mapped { text => text.count }.value)
print(name.mapped { text => text.upper() }.mapped { text => "#{text}!" }.value)
print(name.paired(3))
print(Box.of(2.5).value, Box.of([1, 2]).mapped { list => list.count }.value)

class Tools {
    func twice[Item](item: Item): List[Item] {
        return [item, item]
    }

    func Tools.wrap[Item](item: Item): List[Item] {
        return [item]
    }
}

print(Tools().twice("p"), Tools.wrap(4))

# A method taken as a value, given its type.
const lengths: func(func(String): Int): Box[Int] = name.mapped
print(lengths { text => text.count }.value)
