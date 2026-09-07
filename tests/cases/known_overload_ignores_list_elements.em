## KNOWN HOLE, the same root cause as known_overload_ignores_block_arity reached through
## a different door.
##
## Lists are invariant, so a List<Dog> is not a List<Animal> and the checker resolves
## this to each_of(List<Dog>), which gives back a String. The interpreter's matcher looks
## at the runtime value, sees a list, and stops there -- it does not check what the list
## holds -- so it calls each_of(List<Animal>) and returns an Int into a String.
##
## Container invariance was tightened specifically to close holes of this shape on the
## checker's side. It closed them there. The interpreter was never taught the same rule.

class Animal { }
class Dog extends Animal { }

func each_of(xs: List<Animal>): Int { return 1 }
func each_of(xs: List<Dog>): String { return "dogs" }

var dogs: List<Dog> = [Dog()]
var answer: String = each_of(dogs)
print(answer.upper())
