# Loops and list indexing: the sieve of Eratosthenes.

const limit = 300000
var composite = [false].repeat(limit + 1)
var count = 0
for number in 2..limit {
    if composite[number] {
        continue
    }
    count += 1
    var multiple = number * number
    while multiple <= limit {
        composite[multiple] = true
        multiple += number
    }
}
print(count)
