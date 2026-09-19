struct Counter {
    var count: Int

    func increment() {
        self.count += 1
    }

    func peek(): Int {
        return self.count
    }
}

struct Holder {
    const counter: Counter
    const counts: List[Int]

    func bump() {
        self.counter.increment()
        self.counts.append(1)
    }
}
