# A call whose trailing block is the last thing in an `if`/`while`/`for`
# header, or a `case` subject, needs its disambiguating parentheses kept:
# `Parser.in_control_header` means the `{` right after it always opens the
# statement's own body, not the call's trailing block, so dropping the
# parentheses would make this fail to parse at all.
const items = [1, 2, 3]
if (items.any? { number => number > 2 }) {
    print("found")
}
while (items.any? { number => number > 10 }) {
    print("looping")
}
case (items.any? { number => number > 2 }) {
    when true {
        print("yes")
    }
    else {
        print("no")
    }
}

# The same rule applies however deep the trailing-block call sits: only the
# outermost parentheses need to be kept, since they alone are what resets
# `in_control_header` for everything beneath them.
if (items.filter { x => x > 0 }.count > 0) {
    print("has positive")
}
for x in (items.filter { n => n > 1 }) {
    print(x)
}
