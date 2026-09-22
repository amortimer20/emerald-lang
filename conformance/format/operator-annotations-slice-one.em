struct Money {
    const cents: Int
    @operator("*")
    func times(quantity: Int): Money {
        return Money(self.cents * quantity)
    }
}
