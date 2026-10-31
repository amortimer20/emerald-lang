# Sections 10.4 and 14.3: constructing a nested type sets up that type, not
# its encloser; constructing a subclass sets up its base first, then itself.
func note(text: String): Int {
    print("  setting up #{text}")
    return 0
}

class Theme {
    var Theme.count = note("Theme")

    struct Pair {
        var left: Int

        var Pair.made = note("Pair")
    }
}

class Animal {
    var Animal.made = note("Animal")
}

class Dog extends Animal {
    var Dog.dogs = note("Dog")
}

class Puppy extends Dog {
    var Puppy.small = note("Puppy")
}

print("construct a nested type")
const pair = Theme.Pair(left: 1)
print("construct a subclass of a subclass")
const puppy = Puppy()
print("construct the base")
const animal = Animal()
print("construct the encloser")
const theme = Theme()
print("done")
