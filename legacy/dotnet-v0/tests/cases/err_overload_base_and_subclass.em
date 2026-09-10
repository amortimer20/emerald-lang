## A Dog is an Animal, so a Dog argument matches both. Rejected where it is declared,
## which is what stops static and runtime overload selection from ever disagreeing --
## see conformance_overload_selection.
class Animal { }
class Dog extends Animal { }

func describe(a: Animal): String { return "took Animal" }
func describe(d: Dog): String { return "took Dog" }
