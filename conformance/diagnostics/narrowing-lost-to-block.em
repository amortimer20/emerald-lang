# Sections 4.4 and 4.5: a block may run after a variable it captures is given a
# new value, so a test outside the block proves nothing inside it about a
# variable that is ever assigned.
class Animal {
}

class Dog extends Animal {
    var tricks: Int = 0
}

var pet: Animal = Dog()
if pet is Dog {
    const count_tricks = { => pet.tricks }
    pet = Animal()
    print(count_tricks())
}

var nickname: String? = "Rex"
if nickname != nothing {
    const measure = { => nickname.count }
    nickname = nothing
    print(measure())
}
