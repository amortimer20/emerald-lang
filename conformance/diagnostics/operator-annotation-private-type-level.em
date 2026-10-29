# Section 11.5: `@operator` belongs on an instance method, so a type-level function
# cannot carry it.
struct Money {
    const cents: Int

    @operator("+")
    func Money.combine(other: Money): Money {
        return other
    }
}
