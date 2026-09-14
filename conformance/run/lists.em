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
