# A first annotated arithmetic registration chooses an ordinary method at
# check time. Calling that method by name remains exactly equivalent.
struct Money {
    const cents: Int

    @operator("*")
    func times(quantity: Int): Money {
        return Money(self.cents * quantity)
    }
}

const price = Money(125)
print((price * 3).cents)
print(price.times(3).cents)

# The annotation uses ordinary parameter compatibility, so an Int can widen
# to the Float parameter just as it would in a named method call.
struct Scale {
    const value: Float

    @operator("*")
    func times(factor: Float): Scale {
        return Scale(self.value * factor)
    }
}

print((Scale(1.5) * 2).value)
