# Section 10.1: a getter of a class may change its object, and a struct method that
# changes only an object the struct holds does not change the struct, so it may be
# called on a `const`.
class Counter {
    var reads: Int = 0

    const next: Int {
        self.reads += 1
        return self.reads
    }
}

struct Holder {
    const counter: Counter

    func bump() {
        self.counter.reads += 10
    }
}

const counter = Counter()
print(counter.next, counter.next)
const holder = Holder(counter: counter)
holder.bump()
print(counter.reads)
