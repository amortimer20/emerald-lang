## The third conformance vector, and the one that turned out to need no numbers.
##
## The interpreter picks an overload from the runtime values it is holding. Emitted IL
## will pick from the static types at the call site. Those two rules disagree in every
## language that allows an overload set where a subtype could choose differently --
## in C#, describe(pet) with a Dog in an Animal variable calls the Animal version, and
## a runtime-dispatching interpreter would call the Dog one.
##
## Emerald cannot express the disagreement: an overload set where any argument could
## match two members is rejected where it is declared, so no program exists whose answer
## depends on which rule is used. This file pins that, because the guarantee is what
## lets the emitter resolve statically without auditing the interpreter first.

class Animal { }
class Dog extends Animal { }
trait Swims { }

## Told apart by count -- always safe, since arity is not a matter of types.
func describe(): String { return "nothing" }
func describe(a: Animal): String { return "one" }
func describe(a: Animal, b: Animal): String { return "two" }

var pet: Animal = Dog()
print(describe())
print(describe(pet))
print(describe(Dog()))
print(describe(pet, Dog()))

## Told apart by types with no subtype relation between them, which is the other safe
## shape: no value is ever both.
func label(n: Int): String { return "int" }
func label(s: String): String { return "string" }
func label(d: Dog): String { return "dog" }

print(label(1))
print(label("x"))
print(label(Dog()))

## The four shapes that would have made static and runtime selection disagree are all
## declaration errors, each with its own case:
##   a base and its subclass    err_overload_base_and_subclass
##   a trait and an implementer err_overload_trait_and_class
##   T and T?                   err_overload_nullable
##   Int and Float              err_overload_int_and_float
