## Only one constructor runs — the most derived. A subclass that adds a field and no
## constructor is left with the base's, which cannot know about it.
class Base {
    var a: Int
    constructor(a: Int) { self.a = a }
}

class Child extends Base {
    var b: Int
}

print("never runs")
