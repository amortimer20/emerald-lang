# Section 10.7: type-level members are not inherited, so a subclass does not
# reach its base class's, fields or functions.
class Base {
    var Base.total = 0

    func Base.make(): Base {
        return Base()
    }
}

class Derived extends Base {
}

print(Derived.total)
const made = Derived.make()
