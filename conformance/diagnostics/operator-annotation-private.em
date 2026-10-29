# Section 11.5: `@operator` belongs on a public instance method, so a private method
# cannot carry it.
struct Money {
    const cents: Int

    @operator("*")
    func _times(quantity: Int): Money {
        return Money(self.cents * quantity)
    }
}
