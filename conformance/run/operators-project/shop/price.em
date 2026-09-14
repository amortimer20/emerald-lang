# The prelude's traits are visible in every directory, not only at the root.

struct Price with Ordered, Addable {
    const cents: Int

    @override
    func compare(other: Self): Int {
        return self.cents - other.cents
    }

    @override
    func add(other: Self): Self {
        return Price(self.cents + other.cents)
    }
}
