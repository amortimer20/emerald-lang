class Animal {
    @deprecated("Use `describe` instead.")
    func speak(): String {
        return "..."
    }
}

class Dog extends Animal {
    @override
    func speak(): String {
        return "woof"
    }
}
