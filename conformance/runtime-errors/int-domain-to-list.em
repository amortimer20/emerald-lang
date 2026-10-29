# Section 6.4: materializing the complete `Int` domain raises an ordinary runtime error.
const everything = -9223372036854775807 - 1..9223372036854775807
print(everything.to_list())
