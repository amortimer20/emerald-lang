# Blocks and collection pipelines: map, filter, and reduce.

const numbers = (1..500000).to_list()
const result = numbers.map { n => n * 3 }.filter { n => n % 7 != 0 }.reduce(0) { total, n => total + n % 1000 }
const evens = numbers.count_where { n => n.even?() }
print(result, evens)
