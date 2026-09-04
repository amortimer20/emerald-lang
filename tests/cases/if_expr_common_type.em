## An if expression had its own copy of the first half of CommonType and neither of its
## other rules, so `if c then "x" else nothing` was a type clash rather than a String?,
## and two sibling classes had no common answer at all.
for n in [1, 2, 3] {
    var label: String? = if n.even? then "even" else nothing
    continue if label == nothing
    print(label.upper())
}

class Animal {
    func speak(): String { return "..." }
}

class Dog extends Animal {
    func speak(): String { return "Woof" }
}

class Cat extends Animal {
    func speak(): String { return "Meow" }
}

## Both branches meet at Animal, which is the only type that can describe the answer.
var pet = if true then Dog() else Cat()
print(pet.speak())

## Widening still applies, and is not the same thing as widening to nothing.
var size = if false then 1 else 2.5
print(size)
