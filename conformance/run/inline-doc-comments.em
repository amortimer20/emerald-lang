var x = 1 ## note
var y = 2
print(x, y)

const sum = 1 + ## Continue after the operator.
    2
const grouped = (1 ## Continue inside parentheses.
    + 2)
print(sum, grouped)

func answer(): Int {
    return 42 ## Keep the return on its own line.
}
print(answer())
