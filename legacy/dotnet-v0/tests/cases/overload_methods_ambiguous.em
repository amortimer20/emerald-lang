## Methods obey the same rule functions do: the pair no call could tell apart is
## refused at the declaration.
class Greeter {
    func hi(name: String): String { return "a" }
    func hi(other: String): String { return "b" }
}

print(Greeter().hi("x"))
