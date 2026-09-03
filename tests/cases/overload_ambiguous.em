## Two that no argument could tell apart. §3.2 rejects the pair at the declaration
## rather than leaving each call to resolve between them.
func area(w: Int): Int { return w * w }
func area(w: Int, h: Int = 1): Int { return w * h }

print(area(3))
