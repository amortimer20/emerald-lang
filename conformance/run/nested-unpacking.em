const pairs = [(1, (2, 3)), (4, (5, 6))]
print(pairs.map { (a, (b, c)) => a + b + c })
const f: func((Int, Int), Int): Int = { (x, y), z => x + y + z }
print(f((1, 2), 3))
const (p, (q, r)) = (1, ("two", 3.0))
print(p, q, r)
var left = 1
var middle = "m"
var right = 2.5
(left, (middle, right)) = (7, ("n", 8))
print(left, middle, right)
for (k, (_, y)) in [("a", (1, 2)), ("b", (3, 4))] {
    print(k, y)
}
const ages = ["Ava": (12, "red")]
ages.each { (name, (age, color)) => print(name, age, color) }

# A trailing comma is allowed in names being unpacked, nested or not.
const (one, (two, three,),) = (1, (2, 3))
print(one, two, three)
