# Section 4.2's declaration exercising both meanings of `?`.
func valid?(input: Int?): Bool {
    return input != nothing
}
print(valid?(1))
print(valid?(nothing))

# Section 4.5: `or` supplies the value to use when there is none.
print("42".to_int_maybe().or(0))
print("no".to_int_maybe().or(0))
print("2.5".to_float_maybe().or(0.0))
print("no".to_float_maybe().or(0.0))

# The fallback widens the way it does anywhere else (4.4).
var rate: Float? = nothing
print(rate.or(1))

# The fallback runs only when it is needed.
var asked = 0
func fallback(): Int {
    asked += 1
    return -1
}
var present: Int? = 7
print(present.or(fallback()))
print(asked)

# Section 4.5: narrowing, and what ends it.
var maybe: Int? = 5
if maybe != nothing {
    print(maybe * 2)
}
if maybe == nothing {
    print("absent")
} else {
    print(maybe + 1)
}

# A guard narrows the rest of the block.
func length_of(text: String?): Int {
    return 0 if text == nothing
    return text.count
}
print(length_of("hello"))
print(length_of(nothing))

# Assigning something certain proves it is there; assigning `nothing` un-proves it.
var counter: Int? = nothing
counter = 10
print(counter + 5)

# Section 8.5 and 8.6: absence from a collection.
const numbers = [3, 8, 2, 9]
const empty: [Int] = []
print(numbers.first.or(-1))
print(numbers.last.or(-1))
print(empty.first.or(-1))
print(empty.last.or(-1))
print(numbers.find { n => n > 5 }.or(-1))
print(numbers.find { n => n > 90 }.or(-1))
print(numbers.find_index { n => n > 5 }.or(-1))
print(numbers.find_index { n => n > 90 }.or(-1))

# Section 9.2: an index that may not be there.
print("hello".index_of("ll").or(-1))
print("hello".index_of("z").or(-1))

# Section 4.5: placement is structural.
var whole: [String]? = nothing
var each: [String?] = [nothing, "Ava"]
print(whole)
print(each)

# Section 4.5's one honest cost: `first` on a list whose elements may themselves
# be absent cannot tell "no first element" from "the first element is nothing",
# because optionals never nest. `empty?` is the companion that can.
print(each.first.or("none"))
print(each.empty?())
