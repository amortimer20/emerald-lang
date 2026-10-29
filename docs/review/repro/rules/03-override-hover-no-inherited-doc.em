# Section 3.2: an override without its own documentation inherits the text of the
# declaration it overrides, labelled with its source.
class Animal {
    ## Makes the animal's sound.
    func speak() {
        print("...")
    }
}

class Dog extends Animal {
    @override
    func speak() {
        print("Woof")
    }
}

var dog = Dog()
dog.spe/*cursor*/ak()
