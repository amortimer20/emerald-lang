# Section 10: methods see the instance as `self`.
struct Counter {
    var count: Int
    var history: List[Int]

    # Changes `self`, which the checker works out from the body (4.3).
    func increment() {
        self.count += 1
        self.history.append(self.count)
    }

    # Changes `self` only through another method, which still counts.
    func add(amount: Int) {
        for _ in 1..amount {
            self.increment()
        }
    }

    # Only reads, so it can be called on a `const`.
    func doubled(): Int {
        return self.count * 2
    }

    func empty?(): Bool {
        return self.count == 0
    }

    # A struct's own method is never mistaken for a list's of the same name.
    func append(item: Int) {
        self.history.append(item)
    }

    # Changing a copy of `self` does not change `self`.
    func preview(): Int {
        var next = self
        next.increment()
        return next.count
    }
}

var counter = Counter(0, [])
print(counter.empty?())
counter.increment()
counter.add(2)
counter.append(99)
print(counter, counter.doubled())

# Value semantics: the copy changes alone.
var copy = counter
copy.increment()
print(counter.count, copy.count)

const frozen = Counter(10, [])
print(frozen.doubled(), frozen.preview(), frozen.count)

# A receiver reached through indices and fields changes where it lives.
var counters = [Counter(0, []), Counter(5, [])]
counters[1].increment()
print(counters)

struct Tally {
    var inner: Counter

    func bump() {
        self.inner.add(3)
    }
}

var tally = Tally(Counter(1, []))
tally.bump()
print(tally)

# A temporary may call a method that only reads.
print(Counter(7, []).doubled())

# A constructor may call methods once every field is set.
struct Level {
    var value: Int

    constructor(value: Int) {
        self.value = value
        self.clamp()
    }

    func clamp() {
        if self.value > 10 {
            self.value = 10
        }
    }
}
print(Level(3), Level(30))
