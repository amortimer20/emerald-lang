# Section 8: list literals, indexing, the essential methods, equality, and how
# a list prints.

var scores = [10, 20, 30]
print(scores, scores.count, scores[0])

scores[1] = 25
scores[2] += 5
scores.append(40)
scores.insert(0, 5)
print(scores)

print(scores.remove_at(1), scores.remove_first(), scores.remove_last(), scores)
print(scores.contains?(25), scores.contains?(99), scores.empty?())

var repeated = [3, 1, 3, 2, 3]
repeated.remove(3)
print(repeated)
repeated.remove_all(3)
print(repeated)
repeated.clear()
print(repeated, repeated.empty?())

# Section 8.6's first value-transform methods. The value forms leave their
# receiver alone; the bang forms change only their own copy.
const sequence = [1, 2, 2, 3, 1]
print(sequence.take(3), sequence.take(99), sequence.drop(3), sequence.drop(99), sequence)
print(sequence.reverse(), sequence.unique(), sequence)
var changed = sequence
changed.reverse!()
print(sequence, changed)
changed.unique!()
print(changed)

# Callback transformations are eager and visit each item once, in order.
var calls = 0
const even = sequence.filter { number =>
    calls += 1
    return number.even?()
}
const odd = sequence.reject { number => number.even?() }
print(even, odd, calls, sequence)

# Traversal positions are zero-based and do not change the list.
var indexed: [Int] = []
sequence.each_with_index { number, index =>
    indexed.append(number + index)
}
print(indexed, sequence)

var reverse_seen: [Int] = []
sequence.reverse_each { number => reverse_seen.append(number) }
print(reverse_seen, sequence)

var any_seen: [Int] = []
const has_even = sequence.any? { number =>
    any_seen.append(number)
    return number.even?()
}
print(has_even, any_seen)
var short_seen: [Int] = []
const all_small = sequence.all? { number =>
    short_seen.append(number)
    return number < 2
}
print(all_small, short_seen)
short_seen.clear()
const no_twos = sequence.none? { number =>
    short_seen.append(number)
    return number == 2
}
print(no_twos, short_seen)
short_seen.clear()
const one_even = sequence.one? { number =>
    short_seen.append(number)
    return number.even?()
}
print(one_even, short_seen)
var take_seen: [Int] = []
const prefix = sequence.take_while { number =>
    take_seen.append(number)
    return number <= 2
}
var drop_seen: [Int] = []
const suffix = sequence.drop_while { number =>
    drop_seen.append(number)
    return number <= 2
}
print(prefix, take_seen, suffix, drop_seen, sequence)
var flat_calls = 0
const flattened = sequence.flat_map { number =>
    flat_calls += 1
    return [number, number * 10]
}
print(flattened, flat_calls, sequence)
print(
    sequence.all? { number => number > 0 },
    sequence.none? { number => number < 0 },
    sequence.one? { number => number == 3 },
    sequence.count_where { number => number.even?() }
)
const empty_numbers: [Int] = []
print(empty_numbers.take_while { number => number > 0 }, empty_numbers.drop_while { number => number > 0 })
print(empty_numbers.flat_map { number => [number] })
print(
    empty_numbers.any? { number => number > 0 },
    empty_numbers.all? { number => number > 0 },
    empty_numbers.none? { number => number > 0 },
    empty_numbers.one? { number => number > 0 },
    empty_numbers.count_where { number => number > 0 }
)

# An empty list takes its type from context.
var names: [Int] = []
print(names, names == [])

# Section 4.4 widening: a Float list stores whole numbers as Floats.
var rates: [Float] = [1, 2.5]
rates.append(3)
print(rates, [1, 2.5])

var grid = [[1, 2], [3, 4]]
grid[1][0] = 30
grid[0].append(5)
print(grid, grid == [[1, 2, 5], [30, 4]])

var total = 0
for value in [5, 6, 7] {
    total += value
}
print(total)
