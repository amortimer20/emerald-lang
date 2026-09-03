class Dog {
    var name: String
    constructor(name: String) { self.name = name }
}

var owners: Dictionary<Dog, String> = [:]
print(owners.count)
