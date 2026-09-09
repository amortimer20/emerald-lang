# take, drop, min_by, max_by, group_by and each_with_index -- shared, so every
# container answers them.

var words = ["apple", "fig", "cherry", "date"]

words.each_with_index { word, i => print("#{i}. #{word}") }

print(words.take(2))
print(words.drop(2))
print(words.take(0))
print(words.drop(99))

print(words.min_by { w => w.count() })
print(words.max_by { w => w.count() })
print(words.group_by { w => w.count() })

print((1..10).take(3))
print([3, 1, 2].to_set().take(2))

# A dictionary hands over a key, a value, and then the index
var ages = ["ada": 36, "alan": 41]
ages.each_with_index { (name, age), i => print("#{i} #{name} #{age}") }

var xs = [1, 2, 4]
xs.insert_at(2, 3)
print(xs)
xs.insert_at(4, 5)
print(xs)
