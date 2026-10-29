# The number and order of calls to a type's own equals, hash, and compare are
# observable, and depend on the hash table and sort algorithm.
var calls = 0
struct Key with Hashable {
    var n: Int

    @override
    func equals(other: Key): Bool {
        print("  equals #{self.n} #{other.n}")
        return self.n == other.n
    }

    @override
    func hash(): Int {
        print("  hash #{self.n}")
        return self.n
    }
}

struct Rank with Ordered {
    var n: Int

    @override
    func compare(other: Rank): Int {
        calls += 1
        return self.n - other.n
    }
}

var seen: Set[Key] = [Key(0), Key(8)]
print("contains:")
print(seen.contains?(Key(8)))
var ranks: List[Rank] = []
for n in [5, 3, 9, 1, 7, 2, 8, 6, 4, 0, 11, 15, 13, 12, 14, 10, 19, 17, 16, 18] {
    ranks.append(Rank(n))
}
const sorted = ranks.sort()
print("compare calls in sort:", calls)
