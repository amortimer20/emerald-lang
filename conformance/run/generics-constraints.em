# Section 11.3: a type parameter that requires a trait, `[T with Ordered]`.
# The built-in scalars count as adopting the prelude's comparison and display
# traits, and a value runs its own version of each member.
func largest[T with Ordered](items: List[T]): T? {
    if items.empty?() {
        return nothing
    }
    var best = items[0]
    for item in items {
        best = item if item > best
    }
    return best
}

struct Player with Ordered {
    const name: String
    const score: Int

    @override
    func compare(other: Player): Int {
        return self.score.compare(other.score)
    }
}

print(largest([3, 9, 4]), largest(["pear", "fig"]), largest([1.5, 0.5]))
print(largest([Player("Ava", 3), Player("Noah", 7)]))
const none: List[Int] = []
print(largest(none))

# Ordering and List methods that need an order.
func sorted[T with Ordered](items: List[T]): List[T] {
    return items.sort()
}

func order_of[T with Ordered](first: T, second: T): Int {
    return first.compare(second)
}

print(sorted(["c", "a", "b"]), sorted([Player("a", 2), Player("b", 1)]).map { player => player.name })
print(order_of(1, 2), order_of("b", "a"), order_of(Player("x", 5), Player("y", 5)))

# Keys, through `Hashable`, which builds on `Equatable`.
class Cache[Key with Hashable, Value] {
    var _entries: Dict[Key, Value] = []

    func get(key: Key): Value? {
        return self._entries[key]
    }

    func put(key: Key, value: Value) {
        self._entries[key] = value
    }

    func knows?(key: Key): Bool {
        return self._entries.contains_key?(key)
    }
}

const ages: Cache[String, Int] = Cache()
ages.put("Ava", 12)
print(ages.get("Ava"), ages.get("Noah"), ages.knows?("Ava"))

func distinct[T with Hashable](items: List[T]): Int {
    return items.to_set().count
}

func has[T with Equatable](items: List[T], wanted: T): Bool {
    return items.contains?(wanted) and wanted == items[0]
}

print(distinct([1, 2, 2, 3]), has(["a", "b"], "a"), has([1, 2], 2))

# A struct's own equality runs through `Equatable`.
struct Word with Equatable {
    const text: String

    @override
    func equals(other: Word): Bool {
        return self.text.lower() == other.text.lower()
    }
}

print(has([Word("Hello")], Word("HELLO")))

# Display through `Textual`.
func shown[T with Textual](item: T): String {
    return "<" + item.to_string() + ">"
}

print(shown(4), shown("x"), shown(true))

# A parameter that requires more may be given where less is required.
func twice_distinct[T with Hashable](items: List[T]): Bool {
    return has(items, items[0])
}

print(twice_distinct([5, 6]))

# The comparison members on the built-in scalars.
print(3.compare(4), "b".compare("a"), 2.5.compare(2), 1.equals(1), true.equals(false))
print(5.hash() == 5.hash(), "é".equals("e\u{301}"))

# An optional compares with `==` against a present value of its own type.
func holds?[T with Equatable](maybe: T?, value: T): Bool {
    return maybe == value
}

print(holds?(nothing, 1), holds?(2, 2))
