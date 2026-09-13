# Section 7.3: defaults follow required parameters, and a named argument can
# skip over them.
func greet(name: String, punctuation: String = "!", times: Int = 1) {
    for _ in 1..times {
        print("Hello, #{name}#{punctuation}")
    }
}

greet("Ava")
greet("Bo", "?")
greet("Cy", times: 2)
greet(punctuation: ".", name: "Di")

# A default may read the parameters before it.
func distance(start: Int, end: Int = start + 10): Int {
    return end - start
}
print(distance(5), distance(5, 7), distance(end: 3, start: 1))

# Explicit arguments run left to right as written, then the defaults that
# are still needed, in parameter order.
var log: [String] = []
func note(label: String): Int {
    log.append(label)
    return log.count
}
func record(a: Int = note("a"), b: Int = note("b"), c: Int = note("c")) {
    print(a, b, c)
}
record(c: note("explicit c"))
print(log)

# Whole numbers widen into a Float default just as into a Float argument.
func scale(value: Float, by: Float = 2): Float {
    return value * by
}
print(scale(1.5), scale(1.5, by: 3))

# Methods and custom constructors take them the same way.
struct Account {
    var balance: Int

    constructor(opening: Int = 0) {
        self.balance = opening
    }

    func deposit(amount: Int, fee: Int = 1) {
        self.balance += amount - fee
    }
}

var account = Account()
account.deposit(10)
account.deposit(amount: 5, fee: 0)
print(account, Account(opening: 3))
