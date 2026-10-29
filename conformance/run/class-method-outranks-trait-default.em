# Section 11.2: class methods, including inherited ones, outrank trait defaults.
trait Greeter {
    func greet(): String {
        return "trait default"
    }
}

class Base {
    func greet(): String {
        return "inherited class method"
    }
}

class Child extends Base with Greeter {
}

const child = Child()
print(child.greet())
const greeter: Greeter = child
print(greeter.greet())
