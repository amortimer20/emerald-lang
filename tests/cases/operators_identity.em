## No Equatable, so == asks whether these are the same object.
class Tag {
    var name: String
    constructor(name: String) { self.name = name }
}

var a = Tag("red")
var b = Tag("red")
print(a == a)
print(a == b)
print(a != b)
