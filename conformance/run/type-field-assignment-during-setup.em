# Assigning a type-level field reaches and sets up that type before evaluating
# the value. Setting up another type for the value can grow the module table,
# so the destination must be found again afterwards.
struct Left {
    var Left.value = 1
}

struct Right {
    var Right.a00 = 0
    var Right.a01 = 1
    var Right.a02 = 2
    var Right.a03 = 3
    var Right.a04 = 4
    var Right.a05 = 42
}

Left.value = Right.a05
print(Left.value)
