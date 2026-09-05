class Dog {
    var name: String
    constructor(name: String) { self.name = name }
}

var pack = [Dog("rex")].to_set()
print(pack.count())
