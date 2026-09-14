# A program's own declaration of a prelude name takes its place, but an
# operator still needs the prelude's trait.

trait Ordered {
    func rank(): Int
}

struct Card with Ordered {
    const value: Int

    @override
    func rank(): Int {
        return self.value
    }
}

print(Card(1) < Card(2))
