# Section 4.4: an inline `if` of sibling classes infers their nearest shared base.
class Animal {
    func describe(): String {
        return "an animal"
    }
}

class Dog extends Animal {
}

class Cat extends Animal {
}

func pick(barks: Bool): String {
    var pet = if barks then Dog() else Cat()
    return pet.describe()
}

print(pick(true))
print(pick(false))
var pets = [if true then Dog() else Cat()]
print(pets.type_name)
