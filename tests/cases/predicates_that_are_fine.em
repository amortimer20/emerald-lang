## Every predicate shape that has to keep working.
var numbers = [5, 3, 8]

print(numbers.filter { x => x.even?() })
print(numbers.reject { x => x.odd?() })
print(numbers.any? { x => x > 4 })
print(numbers.all? { x => x > 0 })
print(numbers.find { x => x > 4 })

# Not predicates, so they answer with whatever they like.
print(numbers.map { x => x * 2 })
print(numbers.min_by { x => 0 - x })
print(numbers.group_by { x => x.even?() })
numbers.each { x => print(x) }
