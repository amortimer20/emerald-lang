const fixed = [1, 2]
fixed.append_all([3])
[1].append_all([2])
var items = [1, 2]
items.append_all(["a"])
items.append_all(3)
const words = ["a"]
items.append_all(words)
print(items.repeat("x"))
print(items.index_of("a"))
print(items.index_of())
func find[T](list: List[T], item: T): Int? {
    return list.index_of(item)
}
