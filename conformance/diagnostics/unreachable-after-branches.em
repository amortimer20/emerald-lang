# Section 6.5: a statement after an `if` or `case` every branch of which cannot complete
# is unreachable, reported once at the first such statement.
func sign(number: Int): String {
    if number < 0 {
        return "negative"
    }
    else {
        return "not negative"
    }
    print("after if")
    print("also after")
}

func pick(flag: Bool): Int {
    case flag {
        when true {
            return 1
        }
        when false {
            raise Error("never")
        }
    }
    print("after case")
}
