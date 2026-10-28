# Section 8.6's index_of, repeat, and append_all on a List.

const queue = ["Ada", "Grace", "Alan", "Grace"]
print(queue.index_of("Grace"), queue.index_of("Linus"))
const nobody: List[String] = []
print(nobody.index_of("Ada"))
# An Int finds an equal Float, as `contains?` does.
print([1.5, 2.0].index_of(2), [1.5, 2.0].contains?(2))
# On a list of optionals, `nothing` is an item like any other.
const maybes: List[Int?] = [1, nothing, 3]
print(maybes.index_of(nothing), maybes.index_of(3), maybes.index_of(4))
print([[1], [2, 3]].index_of([2, 3]))
const position = queue.index_of("Alan").or(-1)
print(position)

print([0].repeat(5), [1, 2].repeat(2), [1, 2].repeat(0), nobody.repeat(3))
print("ab".repeat(2))
# Lists are values, so every row is its own.
var grid = [["."].repeat(3)].repeat(3)
grid[1][1] = "X"
print(grid)

var all_scores = [90, 85]
all_scores.append_all([70, 100])
print(all_scores)
all_scores.append_all([])
print(all_scores)
var decimals = [1.5]
decimals.append_all([2, 3])
print(decimals)
const kept = [7, 8]
var copy = kept
copy.append_all([9])
print(kept, copy)

struct Basket {
    var items: List[String]

    func add(more: List[String]) {
        self.items.append_all(more)
    }
}
var basket = Basket(["apple"])
basket.add(["pear", "plum"])
print(basket.items)

func first_place[T with Equatable](items: List[T], item: T): Int? {
    return items.index_of(item)
}
print(first_place(["x", "y"], "y"), first_place([1, 2], 3))
