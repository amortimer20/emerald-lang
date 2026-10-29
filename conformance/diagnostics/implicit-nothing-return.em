# Section 4.5: a function that returns a value on some paths and `nothing` on others
# needs an explicit optional return type.
func first_even(numbers: List[Int]) {
    for number in numbers {
        if number % 2 == 0 {
            return number
        }
    }
    return nothing
}
