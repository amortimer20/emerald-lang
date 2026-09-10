## An Int widens into a Float, so no argument could choose between these.
func show(n: Float): String { return "float" }
func show(n: Int): String { return "int" }

print(show(1))
