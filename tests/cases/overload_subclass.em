## A Dog is an Animal, so a Dog could satisfy either.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal {
}

func feed(a: Animal): String { return "animal" }
func feed(d: Dog): String { return "dog" }

print(feed(Dog("rex")))
