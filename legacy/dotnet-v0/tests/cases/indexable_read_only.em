## at without set_at is a read-only collection.
class Lookup with Indexable {
    var items = ["a", "b"]
    func at(index: Int): String { return self.items[index] }
}

var l = Lookup()
print(l[0])
l[0] = "z"
