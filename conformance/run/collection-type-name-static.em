# Section 4.4: a collection's `type_name` uses its static type, since collections are
# invariant; a tuple's looks at the class of each object it holds.
class Animal {
}

class Dog extends Animal {
}

const animals: List[Animal] = [Dog()]
print(animals.type_name)
print(animals[0].type_name)
const ages: Dict[String, Animal] = ["rex": Dog()]
print(ages.type_name)
const pair: (Animal, Int) = (Dog(), 1)
print(pair.type_name)
