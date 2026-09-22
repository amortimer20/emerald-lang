# A runtime error inside the method an operator runs is reported there, with
# the operator as the call in the trace.

struct Ratio {
    const top: Int
    const bottom: Int

    @operator("/")
    func divide(other: Self): Self {
        return Ratio(self.top * other.bottom, self.bottom // other.top)
    }
}

print(Ratio(1, 2) / Ratio(0, 1))
