# Mistake: redefining a base method without @override (line 8). Source: guide docs/language/objects-and-traits.md.
class Animal {
    func speak() {
        print("...")
    }
}
class Dog extends Animal {
    func speak() {
        print("Woof")
    }
}
Dog().speak()
