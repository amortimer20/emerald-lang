## An Int widens to a Float, so an Int argument matches both. The overlap is one-way and
## still an overlap -- there is a value that could choose either.
func f(n: Int): String { return "took Int" }
func f(n: Float): String { return "took Float" }
