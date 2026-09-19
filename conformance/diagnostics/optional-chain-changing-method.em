# Section 4.5: a struct's changing method has nowhere to write its change
# back to through `?.`, since the receiver there is only ever read as a
# value. A class is unaffected, because its object is shared: mutating it
# through `?.` is exactly as visible afterward as mutating it any other way.

struct Counter {
    var count: Int

    func increment() {
        self.count += 1
    }

    func total(): Int {
        return self.count
    }
}

var maybe_counter: Counter? = Counter(0)
maybe_counter?.increment()
print(maybe_counter?.total())

class SharedCounter {
    var count: Int = 0

    func increment() {
        self.count += 1
    }
}

var maybe_shared: SharedCounter? = SharedCounter()
maybe_shared?.increment()
print(maybe_shared?.count)
