# Section 10.7 across files: a subclass extends a class reached through its
# namespace, and an override keeps the defaults written in the base class's
# file.
class Lion extends Zoo.Animal {
    constructor() {
        super("Leo")
    }

    @override
    func greet(word: String): String {
        return super.greet(word).upper()
    }
}

const lion = Lion()
print(lion.greet())
const seen: Zoo.Animal = lion
print(seen.greet("roar"))
