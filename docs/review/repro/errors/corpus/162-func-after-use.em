# Mistake: calling a function declared further down (none: runs clean). Source: carry-over from Python (NameError habit check).
print(double(4))
func double(n: Int): Int {
    return n * 2
}
