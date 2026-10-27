# Section 11.3: generic enums. A choice's data says the enum's types, as a
# construction's arguments do; a choice without data fits any of them.
enum Chain[Item] {
    end
    link(item: Item, rest: Chain[Item])

    const length: Int {
        return case self {
            when Chain.end then 0
            when Chain.link(_, rest) then 1 + rest.length
        }
    }
}

const numbers = Chain.link(1, Chain.link(2, Chain.end))
print(numbers.length, numbers)
const empty: Chain[String] = Chain.end
print(empty.length, empty)

func first_of[Item](chain: Chain[Item], fallback: Item): Item {
    return case chain {
        when Chain.end then fallback
        when Chain.link(item, _) then item
    }
}

print(first_of(numbers, 0) + 10, first_of(empty, "none"))

# Whole numbers become Floats where the enum's type is Float.
const reals: Chain[Float] = Chain.link(1, Chain.end)
print(reals)

# A binary search tree, whose items need an order.
enum Tree[Item with Ordered] {
    empty
    branch(left: Tree[Item], item: Item, right: Tree[Item])

    func inserted(value: Item): Tree[Item] {
        case self {
            when Tree.empty {
                return Tree.branch(Tree.empty, value, Tree.empty)
            }
            when Tree.branch(left, item, right) {
                return Tree.branch(left.inserted(value), item, right) if value < item
                return Tree.branch(left, item, right.inserted(value))
            }
        }
    }

    func items(): List[Item] {
        return case self {
            when Tree.empty then []
            when Tree.branch(left, item, right) then left.items().chain([item]).chain(right.items())
        }
    }
}

var words: Tree[String] = Tree.empty
words = words.inserted("pear").inserted("fig").inserted("apple")
print(words.items())
var tree: Tree[Int] = Tree.empty
for number in [5, 2, 8, 1] {
    tree = tree.inserted(number)
}
print(tree.items())

# A result of the program's own, whose failure says nothing of `Value`.
enum Outcome[Value] {
    success(value: Value)
    failure(message: String)
}

func half(number: Int): Outcome[Int] {
    return Outcome.failure("odd") if number % 2 != 0
    return Outcome.success(number // 2)
}

for number in [4, 5] {
    case half(number) {
        when Outcome.success(value) {
            print("half is #{value * 1}")
        }
        when Outcome.failure(message) {
            print("failed: #{message}")
        }
    }
}
print(half(4) == Outcome.success(2), half(5))

# An enum of keys is a key, through its types.
enum Pick[Item] {
    nobody
    one(item: Item)
}

const picks: Set[Pick[Int]] = [Pick.one(1), Pick.nobody, Pick.one(1)]
print(picks.count)
