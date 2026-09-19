# Section 8.6's `filter_map`: a block returns one optional result for each
# input item. Present values remain in order; `nothing` is omitted.

func label_if_even(number: Int): String? {
    if number.even?() {
        return "even #{number}"
    }
    return nothing
}

var numbers = [1, 2, 3, 4]
var calls = 0
const labels = numbers.filter_map { number =>
    calls += 1
    return label_if_even(number)
}
print(labels, calls, numbers)

func singleton_if_even(number: Int): List[Int]? {
    if number.even?() {
        return [number]
    }
    return nothing
}

const nested = numbers.filter_map { number => singleton_if_even(number) }
const empty: List[Int] = []
print(nested, empty.filter_map { number => label_if_even(number) })
