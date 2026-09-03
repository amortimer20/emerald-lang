class Dog {
    var name: String
    constructor(name: String) { self.name = name }
    func rename(to: String) { self.name = to }
}

Dog("rex").rename(42)
