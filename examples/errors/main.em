# throw and catch — §3.2 chose exceptions, and this is how you use them

func parse_age(text: String): Int {
    var age = text.to_int_maybe()
    throw "\"#{text}\" is not a number" if age == nothing

    # Past that guard, age is an Int and not an Int?. A throw leaves the function, so
    # everything below it is the case where the check held - the same narrowing an
    # if/else would give, without the else.
    throw Error("an age of #{age} is not believable") unless age.between?(0, 130)
    return age
}

var inputs = ["42", "banana", "900"]

for i in 0..2 {
    try {
        print("ok: #{parse_age(inputs[i])}")
    }
    catch problem {
        print("rejected: #{problem.message()}")
    }
}

# The interpreter's own failures are catchable too, not merely avoidable
try {
    print("banana".to_int())
}
catch problem {
    print("caught a runtime error: #{problem.message()}")
}
