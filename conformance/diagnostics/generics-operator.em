struct Money {
    const cents: Int

    @operator("*")
    func times[Item](count: Int): Money {
        return Money(self.cents * count)
    }
}
