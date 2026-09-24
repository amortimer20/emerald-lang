# Section 10.5's braces rule for nested types (14.3): a private nested type
# written as a type or constructed outside its declaring type, and an enclosing
# type reaching a nested type's private member, which is not written inside its
# braces.
class Outer {
    struct _Hidden {
        var n: Int
    }

    struct Inner {
        var _mine: Int = 1
    }

    func look(inner: Outer.Inner): Int {
        return inner._mine
    }
}

func take(hidden: Outer._Hidden) {}

print(Outer._Hidden(1))
