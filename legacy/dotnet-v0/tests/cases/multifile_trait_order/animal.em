class Animal {
    var name: String

    constructor(name: String) { self.name = name }

    func speak(): String { return "..." }

    func introduce(): String { return "#{self.name} says #{self.speak()}" }
}
