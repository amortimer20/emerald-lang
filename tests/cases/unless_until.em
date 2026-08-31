# unless and until — negated twins of if and while

var ready = false

unless ready {
    print("not ready yet")
}

var countdown = 3
until countdown.zero? {
    print("t-minus #{countdown}")
    countdown -= 1
}
print("liftoff")

# unless as a guard modifier
func check(n: Int): String {
    return "too small" unless n > 10
    return "big enough"
}

print(check(4))
print(check(40))

# reads better than `if not`
var names = ["ada", "grace"]
unless names.empty? {
    print("we have #{names.count} names")
}
