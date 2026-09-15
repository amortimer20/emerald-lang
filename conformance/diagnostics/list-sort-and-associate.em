print([true, false].sort())
const maybe_numbers: [Int?] = [1, nothing]
print(maybe_numbers.sort())
print([1].sort(1))
const frozen = [3, 1, 2]
frozen.sort!()
print([1, 2].sort_by { number => number.even?() })
print([1, 2].unique_by { number => [number] })
print([1, 2].associate { number => number })
print([1, 2].to_dictionary())
