## A conformance vector for the CIL backend: the order construction happens in.
##
## This is the one where copying the host language is most tempting and most wrong,
## because C# and Java do not even agree with each other. C# runs the derived field
## initializers, then the base ones, then the base constructor, then the derived. Java
## runs the base constructor -- base initializers included -- before any derived
## initializer, which is why a derived field read from an overridden method called out of
## a base constructor is null in Java and not in C#.
##
## Emerald does neither: every field initializer runs, base first, before any constructor
## body. So by the time any constructor body executes, every initialized field in the
## whole object has its value. That is what makes the constructor-safety rules coherent --
## see err_constructor_calls_a_method and its neighbours -- and an emitter following C#
## by habit would break it.

func note(s: String): String { print(s)  return s }

class Base {
    var a: String = note("1. base initializer")
    constructor() { print("3. base constructor") }
}

class Derived extends Base {
    var b: String = note("2. derived initializer")
    constructor() {
        super()
        print("4. derived constructor")
    }
}

Derived()
print("---")

## Initializers within one class run top to bottom, so a later one may read an earlier.
func num(n: Int): Int { print("field #{n}")  return n }

class Fields {
    var one: Int = num(1)
    var two: Int = num(2)
    var three: Int = num(3)
}

Fields()
print("---")

## A constructor's own assignments happen after every initializer, so an assignment in the
## body wins over the initializer for the same field rather than racing it.
class Overwrites {
    var value: String = note("initializer ran")
    constructor() { self.value = "constructor won" }
}

print(Overwrites().value)
