# Section 6.3: each arm of a `case` has its own lexical scope, so a name declared in
# one arm is not visible in the next or after the `case`.
const score = 2
case score {
    when 1 {
        var label = "one"
        print(label)
    }
    when 2 {
        var label = "two"
        print(label)
    }
    else {
        print(label)
    }
}
print(label)
