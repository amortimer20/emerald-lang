# 10.1 and 15.1 say only "field by field" / "field-based debug representation".
# The exact form, that private fields are shown, and that base fields come first
# are interpreter choices; conformance/run/private-members.expected encodes
# `Counter(_count: 4, step: 2)`.
class Animal {
    var name: String = "Rex"
    var _secret: Int = 7
}
class Dog extends Animal {
    var breed: String = "lab"
}
struct Point {
    var x: Int
    var _tag: String = "p"
}
print(Dog())
print(Point(1))
