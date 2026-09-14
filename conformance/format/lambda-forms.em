# A lambda whose one statement was written on the arrow's own line stays on
# one line; a lambda with a newline after `=>` keeps its block form.
const numbers = [1, 2, 3]
var total = 0
numbers.each { number => total += number }
numbers.each { number =>
    total += number
    total += 1
}
const doubled = numbers.map { number => number * 2 }
const empty_call = { => total }
