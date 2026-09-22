struct Percent {
    @operator("%")
    func scale(quantity: Int): Percent {
        return self
    }
}
