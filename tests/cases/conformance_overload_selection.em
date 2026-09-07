## The third conformance vector, and the one whose first version overclaimed.
##
## The invariant, stated so it can be tested rather than asserted:
##
##     Every call the checker accepts selects the same declaration the interpreter
##     invokes.
##
## The interpreter picks from the runtime values it is holding; emitted IL will pick from
## the static types at the call site. Where an argument could match two declarations,
## those two rules can choose differently.
##
## Four overlap shapes are refused where they are declared, each with its own case, so
## they cannot diverge: a base and its subclass (err_overload_base_and_subclass), a trait
## and an implementer (err_overload_trait_and_class), T and T? (err_overload_nullable),
## and Int and Float (err_overload_int_and_float). What is below is the rest of the
## surface -- inherited sets, default arguments, callable parameters, collection element
## types, nullable arguments -- checked rather than assumed to follow.
##
## It does not all hold. Three shapes break the invariant, and two of them are unsound
## today rather than only at the boundary:
##   known_overload_diverges_through_a_base
##   known_overload_ignores_block_arity
##   known_overload_ignores_list_elements
## This file is the part that agrees. Those three are the part that does not.

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

## Default arguments. The call site omits one, so the declaration is chosen by a count
## the checker fills in -- a place the two rules could count differently.
func padded(a: Int, b: Int = 2): String { return "#{a}+#{b}" }
func padded(s: String): String { return "string #{s}" }

print(padded(1))
print(padded(1, 5))
print(padded("x"))

## Callable parameters, told apart by their shape rather than by a type name.
func run_it(g: func(): Int): String { return "no args" }
func run_it(g: func(Int): Int): String { return "one arg" }

print(run_it({ 1 }))
## The one-parameter block belongs on the next line and is not here: the interpreter
## picks the wrong declaration for it. See known_overload_ignores_block_arity.

## Collection element types. Lists are invariant, so a List<Dog> is not a List<Animal>
## and no value is ever both -- the overlap the class case has cannot arise here.
func each_of(xs: List<Animal>): String { return "animals" }
func each_of(xs: List<Dog>): String { return "dogs" }

## Likewise only the List<Animal> call is here -- passing a List<Dog> picks the wrong
## declaration. See known_overload_ignores_list_elements.
var animals: List<Animal> = []
print(each_of(animals))

## A nullable argument reaching a parameter that accepts one, with no non-nullable
## sibling to compete -- the shape err_overload_nullable rejects is the one where both
## exist.
func speak(s: String?): String { return s.or("nothing") }
var maybe: String? = nothing
print(speak(maybe))
print(speak("hi"))
