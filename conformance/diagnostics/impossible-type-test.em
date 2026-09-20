# Section 4.4: unrelated classes, and a trait no compatible class adopts,
# cannot have a value in common, so `is` is known false even though it remains
# a valid Bool expression.
class Animal {
}

class Vehicle {
}

trait Named {
}

trait Trained {
}

class Dog extends Animal with Named {
}

const animal: Animal = Animal()
if animal is Vehicle {
    print("unreachable")
}
if animal is Trained {
    print("also unreachable")
}

# Dog makes this test possible for an Animal value, so it has no warning.
if animal is Named {
    print("a dog might be named")
}
