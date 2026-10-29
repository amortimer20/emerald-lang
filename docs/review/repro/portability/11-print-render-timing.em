# 15.2: print's arguments "evaluate left to right"; 5.1: an interpolation
# "displays its value as print would". print renders after evaluating every
# argument, while interpolation renders each part as it goes.
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
