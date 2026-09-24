# A nested type (14.3) shares its enclosing type's one member name space
# (10.3, 10.4): a field, a type-level member, a method, or another nested type
# of the same name is a duplicate, reported at the nested type.
class Outer {
    var Inner: Int
    var Outer.Setting = 1
    func Build() {}

    struct Inner {}
    enum Setting { on }
    struct Build {}
    struct Twice {}
    struct Twice {}
}
