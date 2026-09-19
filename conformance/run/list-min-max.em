# Section 8.6's paired extrema return both optional answers after one traversal.

const numbers = [3, 1, 1, 2]
const decimals = [Float.infinity, 2.5, -1.0]
const words = ["zebra", "apple", "apple"]
const empty: List[Int] = []

const (smallest, largest) = numbers.min_max()
print(smallest.or(0), largest.or(0), empty.min_max())
print(decimals.min_max(), words.min_max())

struct Rank with Ordered {
    const value: Int

    @override
    func compare(other: Self): Int {
        return self.value - other.value
    }
}

const ranks = [Rank(3), Rank(1), Rank(2)]
const (lowest, highest) = ranks.min_max()
print(lowest.or(Rank(0)).value, highest.or(Rank(0)).value)
