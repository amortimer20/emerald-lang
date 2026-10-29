# Section 6.3: a nonexhaustive statement `case` on a `Bool` is a warning, and an
# explicit empty `else { }` acknowledges the gap deliberately.
const ready = true
case ready {
    when true {
        print("go")
    }
}
case ready {
    when true {
        print("go")
    }
    else {
    }
}
