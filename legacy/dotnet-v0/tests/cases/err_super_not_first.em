## Until the base part is built, an inherited field holds nothing — so nothing may run
## before super(...) does.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal {
    var breed: String
    constructor(name: String, breed: String) {
        self.breed = breed
        super(name)
    }
}
