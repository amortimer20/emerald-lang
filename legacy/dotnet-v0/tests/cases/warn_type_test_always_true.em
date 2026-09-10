# Asking whether a Dog is a Dog has one answer, and the branch is not guarding anything.

class Dog {
    func bark(): String { return "Woof" }
}

var d = Dog()
if d is Dog {
    print(d.bark())
}
