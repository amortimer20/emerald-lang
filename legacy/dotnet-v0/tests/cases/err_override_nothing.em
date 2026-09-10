## The other direction: meant to replace, and did not. This is the half that `override`
## catches outright, because the claim is written down and can be checked.
class Animal {
    func speak(): String { return "..." }
}

class Dog extends Animal {
    override func spek(): String { return "Woof" }
}
