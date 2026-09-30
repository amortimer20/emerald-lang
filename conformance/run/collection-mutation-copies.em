# Every native collection mutation must leave another value unchanged.
var a = [1, 2, 3, 4]
var b = a
a.remove_if { n => n % 2 == 0 }
print(a, b)
assert(a == [1, 3])
assert(b == [1, 2, 3, 4])

const original = [3, 1, 2, 2]
a = original
a.append(5)
assert(original == [3, 1, 2, 2])
assert(a == [3, 1, 2, 2, 5])
a = original
a.insert(1, 5)
assert(original == [3, 1, 2, 2])
assert(a == [3, 5, 1, 2, 2])
a = original
a.remove(2)
assert(original == [3, 1, 2, 2])
assert(a == [3, 1, 2])
a = original
a.remove_all(2)
assert(original == [3, 1, 2, 2])
assert(a == [3, 1])
a = original
assert(a.remove_at(1) == 1)
assert(original == [3, 1, 2, 2])
assert(a == [3, 2, 2])
a = original
assert(a.remove_first() == 3)
assert(original == [3, 1, 2, 2])
assert(a == [1, 2, 2])
a = original
assert(a.remove_last() == 2)
assert(original == [3, 1, 2, 2])
assert(a == [3, 1, 2])
a = original
a.clear()
assert(original == [3, 1, 2, 2])
assert(a.empty?())
a = original
a.reverse!()
assert(original == [3, 1, 2, 2])
assert(a == [2, 2, 1, 3])
a = original
a.unique!()
assert(original == [3, 1, 2, 2])
assert(a == [3, 1, 2])
a = original
a.sort!()
assert(original == [3, 1, 2, 2])
assert(a == [1, 2, 2, 3])
a = original
a.shuffle!()
assert(original == [3, 1, 2, 2])
assert(a.sort() == [1, 2, 2, 3])
a = original
const generator = Random(seed: 123)
generator.shuffle!(a)
assert(original == [3, 1, 2, 2])
assert(a.sort() == [1, 2, 2, 3])
a = original
a[0] = 5
assert(original == [3, 1, 2, 2])
assert(a == [5, 1, 2, 2])

const dictionary: Dict[String, Int] = ["a": 1, "b": 2]
var entries = dictionary
entries["c"] = 3
assert(dictionary == ["a": 1, "b": 2])
assert(entries.count == 3)
entries = dictionary
entries["a"] = 4
assert(dictionary == ["a": 1, "b": 2])
assert(entries["a"] == 4)
entries = dictionary
assert(entries.remove("a") == 1)
assert(dictionary == ["a": 1, "b": 2])
assert(entries == ["b": 2])
entries = dictionary
entries.merge(["a": 4, "c": 3])
assert(dictionary == ["a": 1, "b": 2])
assert(entries == ["a": 4, "b": 2, "c": 3])

const members: Set[Int] = [1, 2]
var seen = members
seen.add(3)
assert(members.count == 2 and not members.contains?(3))
assert(seen.count == 3)
seen = members
seen.remove(1)
assert(members.contains?(1))
assert(not seen.contains?(1))

struct Box {
    var items: List[Int]
    func prune() {
        self.items.remove_if { n => n % 2 == 0 }
    }
}
var box = Box([1, 2, 3, 4])
const saved = box
box.prune()
assert(box.items == [1, 3])
assert(saved.items == [1, 2, 3, 4])

var nested = [[1, 2, 3, 4]]
const nested_copy = nested
nested[0].remove_if { n => n % 2 == 0 }
assert(nested == [[1, 3]])
assert(nested_copy == [[1, 2, 3, 4]])
print("collection mutation copies passed")
