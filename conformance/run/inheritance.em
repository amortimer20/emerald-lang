# Section 10.7: a class extends at most one base class. An object of a subclass
# is also an object of its base class, runs its own class's version of each
# method, and reaches the base class's version with `super`.

class Animal {
    const name: String
    var sound_count: Int = 0

    constructor(name: String) {
        self.name = name
    }

    func sound(): String {
        return "..."
    }

    func speak(times: Int = 1): String {
        self.sound_count += times
        return "#{self.name} says #{self.sound().repeat(times)}"
    }

    const kind: String {
        return "animal"
    }
}

class Dog extends Animal {
    var tricks: List[String] = []

    constructor(name: String) {
        super(name)
        self.tricks.append("sit")
    }

    @override
    func sound(): String {
        return "woof"
    }

    @override
    const kind: String {
        return "dog, which is an " + super.kind
    }
}

class Puppy extends Dog {
    constructor(name: String) {
        super(name)
    }

    @override
    func sound(): String {
        return super.sound().upper()
    }

    @override
    func speak(times: Int): String {
        return "(small) " + super.speak(times)
    }
}

# Through the subclass, through the base class, and through a list of either.
const rex = Dog("Rex")
print(rex.speak())
const pet: Animal = rex
print(pet.speak(2), pet.kind)
print(rex.sound_count, rex.tricks)

# An override keeps the base declaration's defaults, whichever version runs.
const animals: List[Animal] = [Animal("Generic"), rex, Puppy("Bit")]
for animal in animals {
    print(animal.speak(), "/", animal.kind)
}

# A subclass object is the same object whichever type sees it.
print(pet == rex, animals[1] == rex, animals[0] == rex)
func loudest(of: Animal): Animal {
    return of
}
print(loudest(rex) == rex)

# A captured method is the version the object's own class runs.
const bark = pet.sound
print(bark())

# Display names the object's own class and shows every field, base class's first.
print(animals[2])

# An optional of the base class holds a subclass object too.
func find(named: String): Animal? {
    if named == "Tiny" {
        return Puppy("Tiny")
    }
    return nothing
}
const found = find("Tiny")
if found != nothing {
    print(found.sound())
}

# Construction runs the base class's part first, then the subclass's field
# defaults, then the rest of its constructor.
func trace(text: String): Int {
    print(text)
    return 0
}

class Base {
    var a: Int = trace("base default")

    constructor(label: String = "none") {
        trace("base constructor, label #{label}")
    }
}

class Middle extends Base {
    var b: Int = trace("middle default")
}

class Top extends Middle {
    var c: Int = trace("top default")

    constructor() {
        trace("top constructor")
    }
}

class Labelled extends Base {
    constructor() {
        super(label: "given")
        trace("labelled constructor")
    }
}

const top = Top()
const labelled = Labelled()

# A base class with a generated constructor, passed to `super` by name.
class Point {
    var x: Int = 0
    var y: Int = 0
}

class NamedPoint extends Point {
    const label: String

    constructor(label: String, y: Int) {
        super(y: y)
        self.label = label
    }
}
print(NamedPoint("p", 5))

# A property overridden with a setter, reaching the base class's with `super`.
class Temperature {
    var celsius: Float = 0

    var reading: Float {
        get {
            return self.celsius
        }
        set {
            self.celsius = value
        }
    }
}

class Clamped extends Temperature {
    @override
    var reading: Float {
        get {
            return super.reading
        }
        set {
            if value > 100 {
                super.reading = 100
            } else {
                super.reading = value
            }
        }
    }
}

const gauge: Temperature = Clamped()
gauge.reading = 250
print(gauge.celsius)
gauge.reading = 20
gauge.reading += 5
print(gauge.reading)

# An override may give a subclass of what the method it replaces gives.
class Shelter {
    func adopt(): Animal {
        return Animal("Stray")
    }
}

class DogShelter extends Shelter {
    @override
    func adopt(): Dog {
        return Dog("Buddy")
    }
}

const shelter: Shelter = DogShelter()
print(shelter.adopt().speak())

# An override may give a value that is always there where the method it
# replaces gives an optional.
class Kennel {
    func resident(): Animal? {
        return nothing
    }
}

class FullKennel extends Kennel {
    @override
    func resident(): Dog {
        return Dog("Scout")
    }
}

const kennels: List[Kennel] = [Kennel(), FullKennel()]
for kennel in kennels {
    const resident = kennel.resident()
    if resident != nothing {
        print(resident.speak())
    } else {
        print("empty")
    }
}

# Private methods cannot be overridden, so a constructor may call one.
class Account {
    var balance: Int

    constructor(opening: Int) {
        self.balance = 0
        self._deposit(opening)
    }

    func _deposit(amount: Int) {
        self.balance += amount
    }
}

class Savings extends Account {
    var rate: Int = 2

    constructor() {
        super(100)
    }
}
print(Savings())

# Called through the subclass itself, an override still takes the default the
# declaration it replaces gives.
const bit = Puppy("Bit")
print(bit.speak())

# Taking a method from an object still being built runs nothing, so a base
# class's constructor may hand one on; it runs the object's own version once
# the object is built.
var introductions: List[func(): String] = []

class Guest {
    const name: String

    constructor(name: String) {
        self.name = name
        remember(self)
    }

    func introduce(): String {
        return self.name
    }
}

func remember(guest: Guest) {
    introductions.append(guest.introduce)
}

class TitledGuest extends Guest {
    const title: String

    constructor(name: String, title: String) {
        super(name)
        self.title = title
    }

    @override
    func introduce(): String {
        return "#{self.title} #{self.name}"
    }
}

const guest = TitledGuest("Ada", "Dr")
print(introductions[0]())
