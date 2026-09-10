## Argument types are checked at the call, not discovered inside the body.
func double(n: Int): Int { return n * 2 }
print(double("not a number"))
