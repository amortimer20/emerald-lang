# Section 4.3 applies to type-level fields, and a type-level function is not a
# variable at all.
struct Limits {
    const Limits.most = 10

    func Limits.reset() {
    }
}

Limits.most = 20
Limits.reset = Limits.reset
