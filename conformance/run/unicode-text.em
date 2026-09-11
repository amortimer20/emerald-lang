# Section 9: strings are Unicode. A character is what a reader sees as one,
# canonically equivalent strings are equal, and case mapping is Unicode's.

var greeting = "h\u{E9}llo \u{1F44B}"
print(greeting.count, greeting[1], greeting[6])

# `e` followed by a combining accent is one character, equal to `é`.
var decomposed = "cafe\u{301}"
print(decomposed.count, decomposed == "caf\u{E9}", decomposed.contains?("e"))
for character in "e\u{301}x" {
    write("[" + character + "]")
}
print()

# A family emoji and two flags.
print("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}".count, "\u{1F1FA}\u{1F1F8}\u{1F1EC}\u{1F1E7}".count)

print("Stra\u{DF}e".upper(), "\u{39F}\u{394}\u{39F}\u{3A3}".lower(), "\u{E9}lan".capitalize())
print("Zebra" < "apple", "apple" < "banana")
