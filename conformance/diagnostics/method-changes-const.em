struct Counter {
    var count: Int

    func increment() {
        self.count += 1
    }

    func peek(): Int {
        return self.count
    }
}

const counter = Counter(0)
print(counter.peek())
counter.increment()
