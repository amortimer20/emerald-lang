struct Distance {
    const meters: Int

    @operator("+")
    func plus(other: Self): Self {
        return Distance(self.meters + other.meters)
    }

    @operator("*")
    func multiply(other: Self): Int {
        return self.meters * other.meters
    }
}
