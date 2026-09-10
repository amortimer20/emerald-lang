class Dog {
    var name: String
    constructor(name: String) { self.name = name }
}

try {
    print("risky")
}
catch e: Dog {
    print("unreachable")
}
