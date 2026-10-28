# Mistake: __init__ constructor (line 5). Source: carry-over from Python.
class Dog {
    var name: String

    func __init__(name: String) {
        self.name = name
    }
}
print(Dog("Rex").name)
