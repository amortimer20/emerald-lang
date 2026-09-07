## What a list holds picks the overload -- and this is the case that could not have been
## fixed by teaching the interpreter's matcher one more rule.
##
## Lists are invariant, so a List<Dog> is not a List<Animal>, and the checker resolves
## this to each_of(List<Dog>). The interpreter cannot reach the same answer from the value
## in hand even in principle: a runtime list carries no element type, and an empty one has
## nothing to inspect at all. Only the checker knows, so only the checker decides.
##
## It used to return an Int into a variable declared String.

class Animal { }
class Dog extends Animal { }

func each_of(xs: List<Animal>): Int { return 1 }
func each_of(xs: List<Dog>): String { return "dogs" }

var dogs: List<Dog> = [Dog()]
var answer: String = each_of(dogs)
print(answer.upper())
