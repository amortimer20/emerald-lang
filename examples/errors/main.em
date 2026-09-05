# throw and catch — §3.2 chose exceptions, and this is how you use them

func parse_age(text: String): Int {
    var age = text.to_int_maybe()
    throw "\"#{text}\" is not a number" if age == nothing
    throw Error("an age of #{age.or(0)} is not believable") unless age.or(0).between?(0, 130)
    return age.or(0)
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
