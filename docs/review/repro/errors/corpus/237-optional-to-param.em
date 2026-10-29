# Mistake: passing an optional to a non-optional parameter (line 6). Source: review brief list.
func square(n: Int): Int {
    return n * n
}
var n = "5".to_int_maybe()
print(square(n))
