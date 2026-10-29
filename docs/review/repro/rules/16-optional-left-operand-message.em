# Section 11.5: the left operand's type decides, and it may not be optional.
struct Money {
    const cents: Int

    @operator("*")
    func times(quantity: Int): Money {
        return Money(self.cents * quantity)
    }
}

const price: Money? = Money(5)
print(price * 3)
