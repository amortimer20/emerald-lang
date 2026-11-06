# Mistake: super() not first in constructor (line 9). Source: guide docs/language/objects-and-traits.md.
class Animal {
    var name: String
}
class Dog extends Animal {
    var tricks: Int
    constructor(name: String) {
        self.tricks = 0
        super(name)
    }
}
print(Dog("Rex").name)
