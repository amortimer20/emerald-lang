# Math.max and Math.min choose between two values of one Ordered type.

print(Math.max(3, 7), Math.min(3, 7), Math.max(-2, -9))
# A whole number beside a Float widens, so the result is a Float either way.
print(Math.min(3, 2.5), Math.max(3, 2.5), Math.max(2.5, 1.0))
print(Math.max("pear", "apple"), Math.min("pear", "apple"))
print(Math.max(Date(2026, 1, 1), Date(2025, 6, 30)))
print(Math.min(Duration(seconds: 90), Duration(minutes: 1)))

struct Score with Ordered {
    const name: String
    const points: Int

    @override
    func compare(other: Score): Int {
        return self.points.compare(other.points)
    }
}
# Equal values give `first`, which an Ordered type can tell apart.
const ada = Score("Ada", 5)
const bob = Score("Bob", 5)
print(Math.max(ada, bob).name, Math.min(ada, bob).name)
print(Math.max(ada, Score("Cy", 9)).name, Math.min(ada, Score("Cy", 9)).name)

func larger[T with Ordered](first: T, second: T): T {
    return Math.max(first, second)
}
print(larger(1, 2.5), larger("a", "b"))

var best_so_far = 0
for score in [4, 9, 2] {
    best_so_far = Math.max(best_so_far, score)
}
print(best_so_far)
print(Emerald.Math.min(1, 2))
