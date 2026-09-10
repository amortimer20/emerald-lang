## super(...) runs the base's constructor on this same object, so the base fills its own
## fields and does its own work — which is the part that assigning them yourself skipped.
class Animal {
    var name: String
    var legs: Int

    constructor(name: String) {
        self.name = name.trim().upper()
        self.legs = 4
    }

    func introduce(): String { return "#{self.name}, #{self.legs} legs" }
}

class Dog extends Animal {
    var breed: String

    constructor(name: String, breed: String) {
        super(name)
        self.breed = breed
    }

    override func introduce(): String { return "#{super.introduce()} (#{self.breed})" }
}

## Three levels: each one calls the one above it.
class Puppy extends Dog {
    var weeks: Int

    constructor(name: String, weeks: Int) {
        super(name, "unknown")
        self.weeks = weeks
    }
}

print(Dog("  rex  ", "lab").introduce())

var p = Puppy("bella", 8)
print(p.introduce())
print(p.weeks)
print(p.legs)

## super names one thing: the class above. Calling it builds that class's part, and
## dotting off it reaches the method it declared.
print(p.name)
