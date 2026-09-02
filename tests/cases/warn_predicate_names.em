## A method returning Bool must end in ?, and one ending in ? must return Bool (§3.4).
func ready(n: Int): Bool { return n > 0 }
func size?(n: Int): Int { return n }

print(ready(1))
print(size?(2))
