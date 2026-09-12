const double = { value: Int => value * 2 }
print(double(21))

const nothing_taken = { => "nothing in" }
print(nothing_taken())

const numbers = [1, 2, 3, 4]
numbers.each { number => write("#{number} ") }
print("")
print(numbers.map { number => number * number })
print(numbers.map { number => "n#{number}" })

# A block is checked against the type expected where it is written, so these
# parameters need no annotation.
const apply: func(func(Int): Int, Int): Int = { block, value => block(value) }
print(apply({ number => number + 1 }, 41))

# `_` takes a value the block does not need, and may be written more than once.
const constant: func(Int, Int): Int = { _, _ => 7 }
print(constant(1, 2))

# A block body on more than one line uses `return` for its result.
const classify = { number: Int =>
    return "even" if number % 2 == 0
    return "odd"
}
print(numbers.map { number => classify(number) })

# A named function is a value.
func triple(value: Int): Int {
    return value * 3
}
const tripler = triple
print(tripler(5))
print(numbers.map(triple))
print(triple == tripler)
