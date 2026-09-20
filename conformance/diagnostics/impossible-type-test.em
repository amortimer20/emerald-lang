# Section 4.4: unrelated classes cannot have a value in common, so `is` is
# known false even though it remains a valid Bool expression.
class Animal {
}

class Vehicle {
}

const animal: Animal = Animal()
if animal is Vehicle {
    print("unreachable")
}
