## An object is held by which object it is. Two dogs with the same name are two keys --
## identity cannot drift as fields do, which is what makes this sound with nothing owed.
class Dog {
    var name: String
    constructor(name: String) { self.name = name }
}

var rex = Dog("rex")
var owners: Dictionary<Dog, String> = [:]
owners.set(rex, "sam")
owners.set(Dog("rex"), "jo")

print(owners.count())
print(owners[rex])

rex.name = "max"
print(owners[rex])
