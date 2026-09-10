## The other side of the four err_ cases beside this one: a constructor may not call a
## method on self or pass self anywhere, and everything else it used to do it still does.
## A rule that costs nothing has to be shown costing nothing.

class Basket {
    var items: List<String>
    var label: String
    var on_ready: func()

    constructor(label: String, on_ready: func()) {
        self.items = []

        ## A method on a field's value, not on self. Nothing dispatches to a subclass
        ## here, and the field is assigned on the line above.
        self.items.add("first")
        self.items.add(label.upper())

        self.label = label

        ## Reading a field back after assigning it.
        self.label = "#{self.label}!"

        ## A field that holds a function. Calling it dispatches to nothing, so it is a
        ## read like any other -- and the read check still requires the assignment first.
        self.on_ready = on_ready
        self.on_ready()

        ## A free function, and another object built from the outside.
        print(shout(self.label))
        print(Tag("side").text)
    }
}

class Tag {
    var text: String
    constructor(text: String) { self.text = text }
}

func shout(s: String): String { return s.upper() }

var b = Basket("fruit") { print("ready") }
print(b.items.join(", "))
print(b.label)

## And the point of the restriction: everything banned inside a constructor is available
## the moment the object exists.
class Counter extends Tag {
    var n: Int
    constructor() {
        super("counter")
        self.n = 0
    }
    func bump(): Int { self.n = self.n + 1  return self.n }
}

var c = Counter()
print(c.bump())
print(c.bump())

func take(t: Tag): String { return t.text }
print(take(c))
