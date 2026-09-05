## A method named without parentheses is the method itself, receiver attached (§3.1).
class Dog {
    var name: String
    constructor(name: String) { self.name = name }
    func speak(): String { return "Woof from #{self.name}" }
}

func twice(f: func(): String) {
    print(f())
    print(f())
}

var rex = Dog("Rex")

## Bound to a name, called later.
var action: func(): String = rex.speak
print(action())

## Passed straight in. This is the shape optional parens made unwritable: reading the
## member gave you the answer, so there was no way to hand over the question.
twice(rex.speak)

## The receiver goes with it, so two of them stay apart.
var fido = Dog("Fido")
twice(fido.speak)
