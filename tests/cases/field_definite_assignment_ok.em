## All the ways a field legitimately gets a value.

## Both branches assign.
class Label {
    var text: String
    constructor(long?: Bool) {
        if long? { self.text = "long" }
        else { self.text = "short" }
    }
}

## A throw abandons the object, so that path owes nothing.
class Checked {
    var text: String
    constructor(raw: String) {
        if raw.empty?() { throw "a label needs text" }
        else { self.text = raw }
    }
}

## Declared with a value; the constructor need not repeat it.
class Counter {
    var hits = 0
}

## Nullable, so nothing is a legal value for it.
class Maybe {
    var note: String?
}

## A subclass with its own constructor calls the base's and then fills its own. It does
## not assign a's field itself: Base's constructor is what gives a its value, and saying
## so is what stops the two drifting apart.
class Base {
    var a: Int
    constructor(a: Int) { self.a = a }
}
class Child extends Base {
    var b: Int
    constructor(a: Int, b: Int) {
        super(a)
        self.b = b
    }
}

print(Label(true).text)
print(Checked("hi").text)
print(Counter().hits)
print(Maybe().note.or("none"))
print(Child(1, 2).a + Child(1, 2).b)
