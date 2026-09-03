## Methods do not overload yet. This used to overwrite in silence.
class Greeter {
    func hi(name: String): String { return "hi #{name}" }
    func hi(n: Int): String { return "hi ##{n}" }
}

print(Greeter().hi("ada"))
