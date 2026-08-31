# Traits: an interface is a trait that implements nothing (§3.2)

trait Swimmer {
    abstract func stamina(): Int      # the trait requires this of you

    func swim(): String {             # the trait provides this to you
        return "swimming for #{self.stamina()} minutes"
    }
}

trait Named {
    abstract func name(): String
}

class Animal {
    abstract func speak(): String

    func introduce(): String {
        return "#{self.name()} says #{self.speak()}"
    }

    abstract func name(): String
}

class Dog extends Animal with Swimmer {
    func name(): String { return "Rex" }
    func speak(): String { return "Woof" }
    func stamina(): Int { return 30 }
}

class Cat extends Animal {
    func name(): String { return "Momo" }
    func speak(): String { return "Meow" }
}

var rex = Dog()
var momo = Cat()

print(rex.introduce())
print(momo.introduce())
print("#{rex.name()} is #{rex.swim()}")

var pets = [rex, momo]
print(pets.map { p => p.speak() }.join(" / "))
