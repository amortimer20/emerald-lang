# Section 15.2: `print` evaluates every argument, then displays them in order; an
# interpolation displays each part as it is evaluated.
class Counter {
    var n: Int = 0
}
func bump(c: Counter): Int {
    c.n += 1
    return c.n
}
const c = Counter()
print(c, bump(c))
print("#{c} #{bump(c)}")
