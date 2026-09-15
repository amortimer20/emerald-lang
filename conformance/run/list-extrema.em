# Section 8.6's extrema use ordinary ordering and return nothing for an empty List.

const whole_numbers = [3, 1, 1, 2]
const decimal_numbers = [Float.infinity, 2.5, -1.0]
const words = ["zebra", "apple", "apple"]
const empty: [Int] = []

print(whole_numbers.min().or(0), whole_numbers.max().or(0), empty.min(), empty.max())
print(decimal_numbers.min().or(0.0), decimal_numbers.max().or(0.0))
print(words.min().or(""), words.max().or(""))

struct Rank with Ordered {
    const value: Int

    @override
    func compare(other: Self): Int {
        return self.value - other.value
    }
}

const ranks = [Rank(3), Rank(1), Rank(2)]
print(ranks.min().or(Rank(0)).value, ranks.max().or(Rank(0)).value)
