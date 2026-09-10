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

# A subclass with something of its own to set up writes its own constructor, and starts
# it by calling the one above. Animal fills its part; Puppy fills the rest.
#
# super(...) has to be the first statement: until it has run, the fields Animal looks
# after are still empty. And you only write it when the base's constructor wants
# something — one that takes nothing is called for you.
class Puppy extends Dog {
    var weeks: Int

    constructor(name: String, weeks: Int) {
        super(name)
        self.weeks = weeks
    }

    override func introduce(): String {
        return "#{super.introduce()}, and is #{self.weeks} weeks old"
    }
}

var rex = Dog("Rex")
var tweety = Bird("Tweety")
var bella = Puppy("Bella", 8)

print(rex.introduce())
print(tweety.introduce())
print("#{rex.name} has #{rex.legs} legs")
print("#{tweety.name} has #{tweety.legs} legs")
print(bella.introduce())

rex.name = "Rexington"
print(rex.introduce())

var pets = [rex, tweety]
print(pets.map { p => p.speak() }.join(" and "))
