# Section 6.4: ranges count upward, and counting down is said in words. A step
# says only how far; the range or method says which way.

var out: [Int] = []
for i in 10.down_to(1) {
    out.append(i)
}
print(out)

out.clear()
for i in 10.down_to(0).step(2) {
    out.append(i)
}
print(out)

out.clear()
for i in (0..10).step(3) {
    out.append(i)
}
print(out)

out.clear()
for i in (1..10).reverse() {
    out.append(i)
}
print(out)

# `reverse` and `step` apply in the order they are written.
out.clear()
for i in (0..10).step(3).reverse() {
    out.append(i)
}
print(out)

# A computed count on the wrong side is empty, so walking a list backwards is
# safe even when the list is empty.
var items = [5, 6, 7]
out.clear()
for i in (0..<items.count).reverse() {
    out.append(items[i])
}
print(out)

var nothing_left: [Int] = []
for i in (0..<nothing_left.count).reverse() {
    print(nothing_left[i])
}
