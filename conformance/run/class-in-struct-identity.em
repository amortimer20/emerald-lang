# Section 10.1: a class stored inside a struct still compares by class identity.
class Owner {
    var name: String

    constructor(name: String) {
        self.name = name
    }
}

struct Pet {
    var name: String
    var owner: Owner
}

const ava = Owner("Ava")
const other_ava = Owner("Ava")
print(Pet(name: "Rex", owner: ava) == Pet(name: "Rex", owner: ava))
print(Pet(name: "Rex", owner: ava) == Pet(name: "Rex", owner: other_ava))
