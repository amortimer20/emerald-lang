# Section 15.4: a repeated group never takes an empty round, and `\B` matches an empty
# text, as in Go and Rust. Python would report an empty last group in each case below.
print(Regex('\B').matches?(""), Regex('\B').find(""))
const plus = Regex('(a|)+').find("aab")
if plus != nothing {
    print(plus.text, "[#{plus.group(1)}]")
}
const star = Regex('(a|)*b').find("ab")
if star != nothing {
    print(star.text, "[#{star.group(1)}]")
}
const nested = Regex('(a*)+').find("aa")
if nested != nothing {
    print(nested.text, "[#{nested.group(1)}]")
}
