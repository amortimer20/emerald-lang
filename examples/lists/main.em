# Lists and the core collection API

var numbers = [5, 3, 8, 1, 9, 2]

print("all:      #{numbers.join(", ")}")
print("count:    #{numbers.count}")
print("sum:      #{numbers.sum}")
print("sorted:   #{numbers.sort.join(", ")}")
print("reversed: #{numbers.reverse.join(", ")}")
print("index 0:  #{numbers[0]}")

# x is known to be an Int here — inferred from the list's element type
var doubled = numbers.map { x => x * 2 }
print("doubled:  #{doubled.join(", ")}")

var evens = numbers.filter { x => x.even? }
print("evens:    #{evens.join(", ")}")

print("any big?  #{numbers.any? { x => x > 8 }}")
print("all pos?  #{numbers.all? { x => x.positive? }}")

# find can miss, so it gives back Int? — the checker makes you handle that
var big = numbers.find { x => x > 100 }
print("found:    #{big.or(0)}")

var names = ["ada", "grace", "alan"]
print("upper:    #{names.map { n => n.upper }.join(" ")}")

names.add("edsger")
print("after add: #{names.join(", ")}")
