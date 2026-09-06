# A branch that cannot fall through makes the rest of the block its else. Without this,
# the shape §3.1 encourages - the one-line guard - was the shape that lost narrowing,
# and every use below it needed a .or(...) that the guard had already made pointless.

func size_of(text: String): Int {
    var n = text.to_int_maybe()
    return 0 if n == nothing
    return n.abs()
}

func described(text: String): String {
    var n = text.to_int_maybe()
    if n == nothing { throw "not a number" }
    return "#{n} is #{if n.even?() then "even" else "odd"}"
}

func first_number(texts: List<String>): Int {
    for text in texts {
        var n = text.to_int_maybe()
        continue if n == nothing
        return n
    }
    return -1
}

# A branch that falls through proves nothing, so this one still needs the fallback.
func loose(text: String): Int {
    var n = text.to_int_maybe()
    if n == nothing { print("no number in #{text}") }
    return n.or(0)
}

print(size_of("-7"))
print(size_of("banana"))
print(described("4"))
print(first_number(["a", "b", "12", "3"]))
print(loose("banana"))

try {
    print(described("nope"))
}
catch problem {
    print("caught: #{problem.message()}")
}
