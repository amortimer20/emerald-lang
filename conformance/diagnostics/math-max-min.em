print(Math.max(1, "a"))
print(Math.max([1], [2]))
const maybe: Int? = 2
print(Math.min(maybe, 1))
print(Math.max(1))
print(Math.min(1, 2, 3))
struct Plain {
    const value: Int
}
print(Math.max(Plain(1), Plain(2)))
func pick[T](first: T, second: T): T {
    return Math.max(first, second)
}
const largest = Math.max
print(Math.max(nothing, 1))
