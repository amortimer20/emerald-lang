# Section 11.3: a generic value's `type_name` is its declaration's bare name, and
# `Bytes` counts as `Equatable` and `Hashable` for a constrained type parameter.
struct Pair[First, Second] {
    const first: First
    const second: Second
}

print(Pair(first: 1, second: "one").type_name)

func same[T with Equatable](left: T, right: T): Bool {
    return left == right
}

func distinct[T with Hashable](items: List[T]): Int {
    const seen: Set[T] = items.to_set()
    return seen.count
}

const a = Bytes.from_list([1, 2])
const b = Bytes.from_list([1, 2])
print(same(a, b), same(a, Bytes.from_list([3])))
print(distinct([a, b, Bytes.from_list([3])]))
