# Ranges are ordinary immutable values rather than syntax limited to a `for`
# header. They retain their exact sequence when passed or stored.

func total(values: Range): Int {
    var result = 0
    for value in values {
        result += value
    }
    return result
}

var odds = (1..10).step(2)
print(odds.count, odds.empty?(), odds.to_list())
print(total(odds))

var empty = 0..<0
print(empty.count, empty.empty?(), empty.to_list())

var block_values: List[Int] = []
4.times { index => block_values.append(index) }
2.up_to(4) { number => block_values.append(number) }
4.down_to(2) { number => block_values.append(number) }
print(block_values)
