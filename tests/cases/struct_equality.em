## §3.2 calls a struct an immutable value type, and a value type whose values are not
## equal when their contents are equal is not one. `Point(1, 2) == Point(1, 2)` was false
## — a wrong answer, silently, to the most obvious question anyone asks of a small value.
## C# gives a struct the same thing for free.
struct Point {
    var x: Int
    var y: Int
}

print(Point(1, 2) == Point(1, 2))
print(Point(1, 2) == Point(9, 9))
print(Point(1, 2) != Point(9, 9))

## Fields compare the same way, so a struct inside a struct compares by value all the way
## down, and a class inside one compares by identity — which is what == means for a class.
struct Inner {
    var n: Int
}

struct Outer {
    var inner: Inner
    var label: String
}

print(Outer(Inner(1), "a") == Outer(Inner(1), "a"))
print(Outer(Inner(1), "a") == Outer(Inner(2), "a"))

class Tag {
    var name: String
    constructor(name: String) { self.name = name }
}

struct Holder {
    var tag: Tag
}

var shared = Tag("x")
print(Holder(shared) == Holder(shared))
print(Holder(Tag("x")) == Holder(Tag("x")))

## A class on its own is still identity: nothing better has been said about it (§3.2).
class Plain {
    var n: Int
    constructor(n: Int) { self.n = n }
}

print(Plain(1) == Plain(1))

## A struct that says what sameness means still decides for itself.
struct Rounded with Equatable {
    var cents: Int

    func equals?(other: Rounded): Bool {
        return self.cents // 100 == other.cents // 100
    }
}

print(Rounded(150) == Rounded(199))
print(Rounded(150) == Rounded(250))
