# Mistake: declaring a local with the parameter's name (line 3). Source: review brief list (shadowing).
func double(n: Int): Int {
    var n = n * 2
    return n
}
print(double(3))
