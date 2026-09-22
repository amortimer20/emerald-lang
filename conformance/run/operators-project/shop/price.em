# `Ordered` is visible in every directory, not only at the root.

struct Price with Ordered {
    const cents: Int

    @override
    func compare(other: Self): Int {
        return self.cents - other.cents
    }

    @operator("+")
    func add(other: Self): Self {
        return Price(self.cents + other.cents)
    }
}
