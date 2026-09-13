func report(scores: [Int]): String {
    var total = 0
    for score in scores {
        add(score)
    }
    return describe()

    func add(score: Int) {
        total += score
    }

    func describe(label: String = "total"): String {
        return "#{label}: #{total} over #{count()}"
    }

    func count(): Int {
        return scores.count
    }
}
print(report([1, 2, 3]))

func even?(n: Int): Bool {
    func odd?(m: Int): Bool {
        if m == 0 {
            return false
        }
        return even?(m - 1)
    }
    if n == 0 {
        return true
    }
    return odd?(n - 1)
}
print(even?(10), even?(7))

func counter(): func(): Int {
    var count = 0
    func next(): Int {
        count += 1
        return count
    }
    return next
}
const tick = counter()
tick()
print(tick())

if true {
    const greeting = "hi"
    func greet(name: String) {
        print("#{greeting}, #{name}")
    }
    greet(name: "Ava")
    [1, 2].each { n => greet(n.to_string()) }
}

func fact(n: Int): Int {
    func go(k: Int, acc: Int): Int {
        if k <= 1 {
            return acc
        }
        return go(k - 1, acc * k)
    }
    return go(n, 1)
}
print(fact(5))
print(counter)

# A nested function that calls the function around it starts a new call, with
# variables of its own, so what `show` needs is not needed by `again`.
func countdown(n: Int) {
    if n > 0 {
        again()
    }
    var label = "at #{n}"
    show()

    func again() {
        countdown(n - 1)
    }

    func show() {
        print(label)
    }
}
countdown(2)

# The same holds when the function that recurses is itself nested.
func launch() {
    countdown(1)

    func countdown(n: Int) {
        if n > 0 {
            again()
        }
        var label = "lift-off in #{n}"
        show()

        func again() {
            countdown(n - 1)
        }

        func show() {
            print(label)
        }
    }
}
launch()

# Each call makes its own `next`, with its own `count`, so the two are
# different functions even though they have the same name.
const first = counter()
const second = counter()
print(first == second, first == first)
