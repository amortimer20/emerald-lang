## Definite assignment checks the end of the constructor, which is necessary and not
## sufficient. Before its assignment a non-nullable String is observably nothing, so this
## compiled and then failed with "Cannot call count on nothing" -- on a field the type
## system had promised could not be missing.
class Person {
    var name: String

    constructor(name: String) {
        print(self.name.count())
        self.name = name
    }
}

print(Person("Ada").name)
