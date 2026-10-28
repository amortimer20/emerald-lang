# Section 8.6: sorting a long list is stable and complete. Past one short run,
# items are merged, and items with equal keys must keep their order.

struct Entry {
    const key: Int
    const order: Int
}

var entries: List[Entry] = []
for index in 0..<200 {
    entries.append(Entry(index * 37 % 10, index))
}
const sorted = entries.sort_by { entry => entry.key }
var stable = true
for index in 1..<sorted.count {
    const before = sorted[index - 1]
    const after = sorted[index]
    if before.key > after.key or before.key == after.key and before.order > after.order {
        stable = false
    }
}
print(sorted.count, stable, sorted[0].key, sorted[sorted.count - 1].key)

var numbers = (0..<500).to_list().map { n => n * 7919 % 500 }
numbers.sort!()
print(numbers == (0..<500).to_list(), numbers.take(5))
print([3.5, 1.25, 2.0].repeat(20).sort().take(4))

# A comparison that fails partway through a merge leaves every item in place.
var decimals = (0..<100).to_list().map { n => (n * 37 % 100).to_float() }
decimals[50] = Float.nan
try {
    decimals.sort!()
}
catch error: RuntimeError {
    print(error.message)
}
print(decimals.count, decimals.filter { x => not x.nan?() }.sum())
