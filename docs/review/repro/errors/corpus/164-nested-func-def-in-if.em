# Mistake: func keyword used in an expression (line 2). Source: carry-over from JavaScript.
var double = func(n: Int): Int {
    return n * 2
}
print(double(3))
