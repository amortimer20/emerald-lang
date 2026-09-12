var (name, age) = ("Ada", 36)
print(name, age)

const (who, _, active) = ("Grace", 45, true)
print(who, active)

var left = 1
var right = 2
(left, right) = (right, left)
print(left, right)

const pairs = [("a", 1), ("b", 2)]
for (letter, number) in pairs {
    print(letter, number)
}
print(pairs.map { (letter, number) => letter + number.to_string() })

func divide(value: Int, by: Int): (Int, Int) {
    return (value // by, value % by)
}
const (whole, rest) = divide(17, 5)
print(whole, rest)
