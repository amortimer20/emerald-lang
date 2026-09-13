struct Counter {
    var count: Int = 0
    const step: Int = 1

    func increment() {
        self.count += self.step
    }

    func peek(): Int {
        return self.count
    }

    func plus(amount: Int): Int {
        return self.count + amount
    }

    func counter_of_self(): func(): Int {
        return self.peek
    }
}

var counter = Counter()
const advance = counter.increment
advance()
advance()
print(counter.count)          # 0: the captured copy changed, not counter
const peek = counter.peek
counter.increment()
print(peek())                 # 0: peek captured before the change
print(counter.peek())         # 1

var shared = Counter(step: 5)
const bump = shared.increment
const read = shared.peek
bump()
print(read())                 # 0: each capture has its own copy

func twice(action: func()) {
    action()
    action()
}
var tally = Counter()
const tick = tally.increment
twice(tick)
twice(tick)
print(tally.count)

const adders = [counter.plus, Counter(count: 10).plus]
print(adders.map { add => add(1) })
print([1, 2, 3].map(counter.plus))
print(counter.counter_of_self()())
print(advance)
print(advance == advance, advance == counter.increment)

# A changing method keeps changing its own copy from one call to the next.
struct Ticket {
    var number: Int = 0

    func next(): Int {
        self.number += 1
        return self.number
    }
}
const office = Ticket()
const draw = office.next
print(draw(), draw(), draw())
print(office.number)
