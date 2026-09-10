## §3.2 lets a subclass's method replace what it inherits, and nothing used to say which
## of the two mistakes you had made — meaning to replace and failing, or replacing without
## meaning to. `override` is now required wherever something is actually replaced.
class Animal {
    func speak(): String { return "generic noise" }
}

class Dog extends Animal {
    ## super reaches what this replaced. Without it, self.speak() here was not an error
    ## but a stack overflow that killed the process — not even catchable.
    override func speak(): String { return "Woof, not #{super.speak()}" }
}

print(Dog().speak())

## Each super goes exactly one step up, from the class that declared the running method —
## not from the instance's own class, which would loop on a three-level chain.
class Base {
    func describe(): String { return "base" }
}

class Middle extends Base {
    override func describe(): String { return "middle over #{super.describe()}" }
}

class Leaf extends Middle {
    override func describe(): String { return "leaf over #{super.describe()}" }
}

print(Leaf().describe())

## A trait's default is an implementation too, so replacing one is an override, and super
## reaches it — the class's own methods are merged over the trait's, and a copy is kept
## precisely so the replaced one is still there.
trait Swimmer {
    abstract func stamina(): Int

    func swim(): String { return "swims #{self.stamina()}m" }
}

class Fish with Swimmer {
    ## Implementing an abstract member replaces nothing, so it needs no keyword.
    func stamina(): Int { return 99 }

    override func swim(): String { return "#{super.swim()}, gracefully" }
}

print(Fish().swim())
