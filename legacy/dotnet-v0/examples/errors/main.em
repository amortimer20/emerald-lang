# throw and catch — §3.2 chose exceptions, and this is how you use them

# Error is an ordinary class from the prelude, so a program declares its own kinds of
# failure with nothing but extends. A subclass that adds nothing inherits the
# constructor, and one that adds a field writes its own and calls super.
class NotANumber extends Error { }

class OutOfRange extends Error {
    var limit: Int

    constructor(message: String, limit: Int) {
        super(message)
        self.limit = limit
    }
}

func parse_age(text: String): Int {
    var age = text.to_int_maybe()
    throw NotANumber("\"#{text}\" is not a number") if age == nothing

    # Past that guard, age is an Int and not an Int?. A throw leaves the function, so
    # everything below it is the case where the check held - the same narrowing an
    # if/else would give, without the else.
    throw OutOfRange("an age of #{age} is not believable", 130) unless age.between?(0, 130)
    return age
}

var inputs = ["42", "banana", "900"]

for i in 0..2 {
    try {
        print("ok: #{parse_age(inputs[i])}")
    }
    catch problem: NotANumber {
        print("rejected: #{problem.message}")
    }
    catch problem: OutOfRange {
        # The declared type is what the handler gets, so the error's own fields are here.
        print("rejected: #{problem.message} (limit #{problem.limit})")
    }
}

# A clause with no type takes anything, which is what a program that does not care
# should write. The interpreter's own failures arrive as a plain Error, so this catches
# them too — they are recoverable, not merely avoidable.
try {
    print("banana".to_int())
}
catch problem {
    print("caught a runtime error: #{problem.message}")
}

# throw "text" is shorthand for throw Error("text"), so the short form still works and
# still lands in the untyped clause below.
try {
    throw "something simple"
}
catch problem {
    print("caught: #{problem.message}")
}
