# unless — the negated twin of if

var ready = false

unless ready {
    print("not ready yet")
}

# The loop it used to have a twin for. `until` was cut: three appearances in the whole
# corpus and every one of them was `until` demonstrating itself, so `while not` is the
# only spelling now -- and one fewer keyword is one fewer word nobody can name a
# variable after.
var countdown = 3
while not countdown.zero?() {
    print("t-minus #{countdown}")
    countdown -= 1
}
print("liftoff")

# unless as a guard modifier, which is where most of its 21 uses are
func check(n: Int): String {
    return "too small" unless n > 10
    return "big enough"
}

print(check(4))
print(check(40))

# reads better than `if not`
var names = ["ada", "grace"]
unless names.empty?() {
    print("we have #{names.count()} names")
}
