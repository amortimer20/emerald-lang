class Greeter {
    func hi(name: String): String { return "a" }
    func hi(n: Int): String { return "b" }
}

print(Greeter().hi(true))
