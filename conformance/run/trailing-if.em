# Section 6.2: a trailing `if` guards one statement. It is the guard form, so
# there is no `unless`.

func sign(number: Int): Int {
    return -1 if number < 0
    return 0 if number == 0
    return 1
}

func report(ready: Bool) {
    return if not ready
    print(1)
}

print(sign(-4), sign(0), sign(9))
report(false)
report(true)

var score = 5
score += 10 if score > 3
print(score) if score > 10
