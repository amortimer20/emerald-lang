# Section 11.5: an `@operator` method takes one required parameter and has an explicit
# result type.
struct Money {
    const cents: Int

    @operator("*")
    func times(quantity: Int, extra: Int): Money {
        return Money(self.cents * quantity)
    }

    @operator("-")
    func less(amount: Int = 1): Money {
        return Money(self.cents - amount)
    }

    @operator("/")
    func split(parts: Int) {
        print(parts)
    }
}
