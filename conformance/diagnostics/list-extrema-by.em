print([1, 2].min_by { number => number.even?() })
const maybe_numbers: [Int?] = [1, nothing]
print(maybe_numbers.max_by { number => number.or(0) })
print([1].min_by { number => nothing })
print([1].max_by())
func maybe_key(number: Int): Int? {
    if number == 1 {
        return nothing
    }
    return number
}
print([1].max_by { number => maybe_key(number) })
