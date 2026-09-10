# The whole file is the class body — no braces, no nesting (§3.3).
class Animal

var name: String

constructor(name: String) {
    self.name = name
}

abstract func speak(): String

func introduce(): String {
    return "#{self.name} says #{self.speak()}"
}
