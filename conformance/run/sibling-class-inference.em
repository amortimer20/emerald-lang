# Section 10.7: a list, dictionary, or value-producing `case` whose elements
# or arms are different but related classes infers their nearest shared base,
# the same base an explicit `List[Animal]` annotation already accepts them
# under, rather than reporting a mismatch.

class Animal {
    var name: String

    constructor(name: String) {
        self.name = name
    }
}

class Dog extends Animal {
    constructor(name: String) {
        super(name)
    }
}

class Cat extends Animal {
    constructor(name: String) {
        super(name)
    }
}

# Two siblings under one base.
const pair = [Dog("Rex"), Cat("Tom")]
print(pair.count, pair[0].name, pair[1].name)

# Three: two siblings plus the base itself.
const trio = [Dog("Rex"), Cat("Tom"), Animal("Generic")]
print(trio.count)

# A deeper subclass finds the same shared base as its sibling, not some
# looser common one.
class Puppy extends Dog {
    constructor(name: String) {
        super(name)
    }
}
const deeper = [Puppy("Bit"), Cat("Tom")]
print(deeper.count, deeper[0].name)

# Dictionary values widen the same way.
const zoo = ["dog": Dog("Rex"), "cat": Cat("Tom")]
print(zoo.count, zoo["dog"].or(Animal("?")).name)

# A value-producing `case`'s arms widen the same way.
func pet_for(kind: String): Animal {
    return case kind {
        when "dog" then Dog("Rex")
        when "cat" then Cat("Tom")
        else then Animal("Unknown")
    }
}
print(pet_for("dog").name, pet_for("cat").name, pet_for("fish").name)
