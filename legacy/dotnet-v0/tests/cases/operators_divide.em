## / through Dividable. The right side need not be the same type.
struct Ratio with Dividable {
    var value: Float

    constructor(value: Float) {
        self.value = value
    }

    func divide(by: Int): Ratio {
        return Ratio(self.value / by)
    }

    func to_string(): String { return "#{self.value}" }
}

print((Ratio(10.0) / 4).to_string())
print((Ratio(1.0) / 3).to_string())
