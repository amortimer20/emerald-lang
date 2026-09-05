## The base's constructor needs an argument, so this class has to say what to pass it.
## Before chaining existed the fix was to assign name here, which compiled and silently
## skipped whatever Animal's constructor did with it.
class Animal {
    var name: String
    constructor(name: String) { self.name = name }
}

class Dog extends Animal {
    var breed: String
    constructor(breed: String) { self.breed = breed }
}
