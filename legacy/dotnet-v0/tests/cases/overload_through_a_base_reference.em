## The static type at the call site picks the overload, and the object underneath does
## not get a vote.
##
## Sub.go(Dog) is not an override of Base.go(Animal) -- a different parameter type makes
## it a new overload, and since overloads inherit, a Sub has both. Through a Sub, go(Dog)
## is the more specific and wins. Through a Base, the only candidate Base declares is
## go(Animal), so that is what a reader sees and that is what runs.
##
## This used to print "sub Dog" twice: the interpreter looked at the runtime object,
## found the whole inherited set, and picked the more specific version -- an answer no
## compiled backend would ever give, since emitted IL binds from the static type.

class Animal { }
class Dog extends Animal { }

class Base {
    func go(a: Animal): String { return "base Animal" }
}

class Sub extends Base {
    func go(d: Dog): String { return "sub Dog" }
}

var s = Sub()
var b: Base = s

## Both rules agree here.
print(s.go(Dog()))

## And disagree here. A backend prints "base Animal".
print(b.go(Dog()))
