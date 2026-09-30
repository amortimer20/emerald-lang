class Counter {
    func times(block: func(Int)) {
        block(42)
    }

    func up_to(limit: Int, block: func(Int)) {
        block(limit + 10)
    }

    func down_to(limit: Int, block: func(Int)) {
        block(limit - 10)
    }
}

class Child extends Counter {
}

const counter = Counter()
counter.times { number => print(number) }
counter.up_to(3) { number => print(number) }
counter.down_to(3) { number => print(number) }
Child().times { number => print(number) }

struct Values {
    func up_to(limit: Int): List[Int] {
        return [limit, limit + 1]
    }
}

for number in Values().up_to(7) {
    print(number)
}
print(Values().up_to(7).reverse())

struct Ranges {
    func down_to(limit: Int): Range {
        return 1..limit
    }
}

for number in Ranges().down_to(3).step(2) {
    print(number)
}

1.times { number => print(number) }
1.up_to(2) { number => print(number) }
2.down_to(1) { number => print(number) }
