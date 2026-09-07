## The other way to get it wrong: a block that answers with a value rather than with
## yes or no. Nothing was checking, so the Int was read for truthiness.
var numbers = [5, 3, 8]

print(numbers.any? { x => x + 1 })
