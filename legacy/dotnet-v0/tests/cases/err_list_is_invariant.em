## A mutable container is invariant: a List<Dog> is not a List<Animal>.
##
## Compatible element types read as the obvious rule and are unsound, because both names
## are then one list. Adding an Animal through the second corrupts what the first says it
## holds, and the failure lands on a read that is written correctly -- fully annotated
## code breaking its own guarantee through an alias.
class Animal { }

class Dog extends Animal {
    func bark(): String { return "woof" }
}

var dogs: List<Dog> = [Dog()]
var animals: List<Animal> = dogs

animals.add(Animal())
print(dogs[1].bark())
