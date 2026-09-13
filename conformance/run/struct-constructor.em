# Section 10.2: a custom constructor replaces the generated one.
struct Vector2 {
    var x: Float
    var y: Float

    constructor(x: Float, y: Float) {
        self.x = x
        self.y = y
    }
}

# Whole numbers widen into Float parameters and fields.
print(Vector2(1, 2.5))

var opened: [Account] = []

struct Account {
    const owner: String
    var balance: Int
    var history: [Int]

    constructor(owner: String, opening: Int) {
        # A `const` field is set once, here, and never again.
        self.owner = owner.upper()
        if opening < 0 {
            self.balance = 0
        }
        else {
            self.balance = opening
        }
        self.history = []
        self.history.append(self.balance)
        # Once every field is set, `self` is an ordinary value. Storing it
        # shares it, so the change below copies rather than reaching back.
        opened.append(self)
        self.balance += 1
    }
}

const ava = Account("ava", -5)
print(ava.owner, ava.balance, ava.history)
print(Account("bo", 10))
print(opened)

# An early bare `return` after every field is set.
struct Label {
    var text: String

    constructor(text: String) {
        if text == "" {
            self.text = "(none)"
            return
        }
        self.text = text
    }
}
print(Label("").text, Label("hi").text)

# A constructor may build its own type.
struct Chain {
    var depth: Int
    var label: String

    constructor(depth: Int) {
        self.depth = depth
        if depth == 0 {
            self.label = "end"
            return
        }
        self.label = "link to " + Chain(depth - 1).label
    }
}
print(Chain(2))

# Every path through an `if` without `else` may set a `var` field again.
struct Clamp {
    var value: Int

    constructor(value: Int) {
        self.value = value
        if value > 10 {
            self.value = 10
        }
    }
}
print(Clamp(4).value, Clamp(40).value)

struct Marker {
    constructor() {
        print("making", self)
    }
}
print(Marker())
