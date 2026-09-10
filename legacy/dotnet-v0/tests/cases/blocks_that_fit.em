# What a block may still do. Naming fewer than it is handed is fine, and naming none at
# all is how a block that only acts is written.

var numbers = [1, 2, 3]

print(numbers.map { n => n * 2 }.join(","))
print(numbers.filter { n => n.even?() }.join(","))
print(numbers.reduce(0) { total, n => total + n })

numbers.each { n => print("item #{n}") }
3.times { print("again") }

var ages = ["ada": 36, "bo": 7]
ages.each { (who, age) => print("#{who} is #{age}") }

# Naming one thing on a dictionary gets the one thing it hands over, which is the whole
# pair. This printed the key before a dictionary's element became a pair everywhere, and
# the checker called it a pair while it did — the disagreement that ended the two-value
# block shape.
ages.each { entry => print(entry) }

# A block of more than one line says which value it gives.
print(numbers.map { n =>
    var trebled = n * 3
    return trebled
}.join(","))
