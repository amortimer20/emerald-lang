struct Counter {
    var count: Int

    func increment() {
        self.count += 1
    }

    func peek(): Int {
        return self.count
    }
}

var counter = Counter(0)
counter.decrement()
counter.count()
counter.peek(1)
