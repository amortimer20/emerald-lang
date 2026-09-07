## The same overlap reached through a trait rather than a base class.
trait Swims { }
class Dog with Swims { }

func f(s: Swims): String { return "took Swims" }
func f(d: Dog): String { return "took Dog" }
