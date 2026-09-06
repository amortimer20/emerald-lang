# One vocabulary, four containers. Before this only List had any of it.

print((1..5).map { n => n * n })
print((1..10).filter { n => n % 2 == 0 })
print((1..100).sum())
print((1..5).to_list())
print((1..5).reduce(0) { total, n => total + n })
print((1..5).find { n => n > 3 })

var set = [3, 1, 2].to_set()
print(set.map { n => n * 10 })
print(set.any? { n => n > 2 })
print(set.all? { n => n > 0 })
print(set.count())

# filter narrows a container without changing what it is, so this is still a Set
var evens = set.filter { n => n % 2 == 0 }
print(evens.union([9].to_set()))

var scores = ["ada": 90, "grace": 95, "alan": 80]
print(scores.map { name, score => "#{name}:#{score}" })
print(scores.filter { name, score => score > 85 })
print(scores.any? { name, score => score > 90 })
print(scores.count())

# A range filtered is a list, because 1..10 without its odds is not a range
var odds = (1..6).reject { n => n % 2 == 0 }
print(odds.reverse())

# Whole numbers still sum to a whole number, and fractions no longer sum to zero
print([1, 2, 3].sum())
print([1.5, 2.5].sum())
