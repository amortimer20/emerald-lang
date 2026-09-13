# Section 10.4: a type-level member belongs to the type, so it has no `self`.
struct Counter {
    var value: Int
    var Counter.start = self.value

    func Counter.make(): Counter {
        return Counter(self.value)
    }
}
