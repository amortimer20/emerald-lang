## The equals? is not on Animal, it is on a kind of Animal -- and a Set<Animal> really
## holds Dogs. Finding by identity here would quietly disagree with what == says about the
## same two dogs, so the set is refused where the divergence would arise.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal with Equatable {
    func equals?(other: Dog): Bool { return self.name == other.name }
}

var pen: Set<Animal> = [].to_set()
