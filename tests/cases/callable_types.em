## A function's type is its header with the name removed: `func greet(name: String):
## String` has the type `func(String): String`. No second grammar and no new punctuation
## — and the return is left off when there is none, exactly as on a declaration.
##
## Until this existed only built-ins could take a block, so §2.3's "libraries feel like
## language" was a claim nothing could fund.
func do_twice(action: func()) {
    action()
    action()
}

do_twice { print("hi") }

## A block's parameters are typed from the shape the function asks for — the same
## contextual inference that lets numbers.map { x => x * 2 } know x is an Int, now
## available to a function anyone can write.
func transform(items: List<Int>, change: func(Int): Int): List<Int> {
    return items.map { n => change(n) }
}

print(transform([1, 2, 3]) { n => n * 2 }.join(", "))

func pick(items: List<String>, keep: func(String): Bool): List<String> {
    var kept: List<String> = []
    for item in items {
        kept.add(item) if keep(item)
    }
    return kept
}

print(pick(["ada", "bo", "cy"]) { name => name.length() > 2 }.join(", "))

## A named function goes where a block does.
func double(n: Int): Int { return n * 2 }

func apply(n: Int, change: func(Int): Int): Int { return change(n) }

print(apply(21, double))

## Functions are values: they go in variables, in lists, and out of other functions.
var tripled: func(Int): Int = { n => n * 3 }
print(tripled(4))

var steps: List<func(Int): Int> = []
steps.add({ n => n + 1 })
steps.add({ n => n * 2 })

var value = 5
for step in steps { value = step(value) }
print(value)

func compose(first: func(Int): Int, second: func(Int): Int): func(Int): Int {
    return { n => second(first(n)) }
}

print(compose({ n => n + 1 }, { n => n * 2 })(5))

## A field holding one. `button.on_click` is the function; `button.on_click()` calls it —
## the parser keeps them apart, because only a written ( or a trailing block makes a call.
## Without that, every callback stored in a field was a silent no-op.
class Button {
    var label: String
    var on_click: func()

    constructor(label: String, on_click: func()) {
        self.label = label
        self.on_click = on_click
    }

    func press() {
        print("pressing #{self.label}")
        self.on_click()
    }
}

Button("OK") { print("clicked") }.press()
