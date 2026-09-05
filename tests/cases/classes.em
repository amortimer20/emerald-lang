# Classes: fields, constructor, methods, self, and single inheritance

class Animal {
    var name: String
    var legs: Int = 4

    constructor(name: String) {
        self.name = name
    }

    func speak(): String {
        return "..."
    }

    func introduce(): String {
        return "#{self.name} says #{self.speak()}"
    }
}

class Dog extends Animal {
    override func speak(): String {
        return "Woof"
    }
}

class Bird extends Animal {
    var legs: Int = 2

    override func speak(): String {
        return "Tweet"
    }
}

var rex = Dog("Rex")
var tweety = Bird("Tweety")

print(rex.introduce())
print(tweety.introduce())
print("#{rex.name} has #{rex.legs} legs")
print("#{tweety.name} has #{tweety.legs} legs")

rex.name = "Rexington"
print(rex.introduce())

var pets = [rex, tweety]
print(pets.map { p => p.speak() }.join(" and "))
