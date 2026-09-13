struct Counter {
    var count: Int

    func increment() {
        self.count += 1
    }

    func peek(): Int {
        return self.count
    }
}

func advance(counter: Counter) {
    counter.increment()
}
