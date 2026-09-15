# Section 8.6's ordering: `sort`/`sort!` use the same ordering `min` and `max`
# do, and `sort_by` reorders elements by a computed key while ties keep their
# input order.

const whole_numbers = [3, 1, 2, 1]
print(whole_numbers.sort())
print(whole_numbers)

var mutable_numbers = [3, 1, 2, 1]
mutable_numbers.sort!()
print(mutable_numbers)

const words = ["pear", "fig", "apple", "kiwi"]
print(words.sort_by { word => word.count })

struct Rank with Ordered {
    const value: Int

    @override
    func compare(other: Self): Int {
        return self.value - other.value
    }
}

const ranks = [Rank(3), Rank(1), Rank(2)]
const sorted_ranks = ranks.sort()
print(sorted_ranks[0].value, sorted_ranks[1].value, sorted_ranks[2].value)

const empty: [Int] = []
print(empty.sort())
