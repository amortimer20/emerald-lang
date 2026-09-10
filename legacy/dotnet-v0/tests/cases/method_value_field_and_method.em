## Whether a callable is a field or a method is the author's business, not the caller's.
## Under optional parens it was the caller's: a field handed back the function and a
## method ran it, so which spelling worked depended on a declaration you could not see.
class Button {
    var on_click: func(): String
    constructor(on_click: func(): String) { self.on_click = on_click }
    func label(): String { return "press me" }
}

func run(f: func(): String) { print(f()) }

var b = Button({ "clicked" })

## Both are read the same way and both are called the same way.
run(b.on_click)
run(b.label)
print(b.on_click())
print(b.label())
