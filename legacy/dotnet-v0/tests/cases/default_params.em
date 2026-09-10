## Defaults on a function, a constructor, a method, and a static method.
func greet(name: String, greeting: String = "Hello"): String {
    return "#{greeting}, #{name}!"
}

print(greet("Ana"))
print(greet("Bo", "Welcome"))

## A default may refer to a parameter to its left.
func box(width: Int, height: Int = width): String {
    return "#{width}x#{height}"
}

print(box(3))
print(box(3, 5))

class Greeter {
    var name: String
    constructor(name: String = "world") { self.name = name }
    func hello(punct: String = "!"): String { return "hi #{self.name}#{punct}" }
}

print(Greeter().hello())
print(Greeter("ana").hello("?"))

class Make {
    static func tag(text: String, level: Int = 1): String {
        return "#{level}:#{text}"
    }
}

print(Make.tag("a"))
print(Make.tag("b", 3))
