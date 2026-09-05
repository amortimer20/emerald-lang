# Loops: for, while, break, continue (§3.1)

# `for` walks three things. There is no C-style for loop, which is why the keyword
# is `for` and not `foreach` — there is nothing for `foreach` to be different from.

for i in 1..3 {
    print("range: #{i}")
}

for animal in ["cat", "dog", "fox"] {
    print("list:   #{animal}")
}

# A string yields characters — real ones. `é` is one turn of the loop, not two,
# and neither is a family emoji.
for letter in "héllo" {
    print("string: #{letter}")
}

print()

# The loop variable's type comes from what is being walked, so the checker knows
# `word` is a String here and `word.length` is checked like any other call.
for word in ["apple", "fig"] {
    print("#{word} is #{word.length()} letters")
}

print()

# break leaves the loop; continue skips to the next turn. Both take the guard
# modifier, so the common shape is one line.
for n in 1..20 {
    continue if n % 3 != 0
    break if n > 12
    print("multiple of three: #{n}")
}

print()

# while, with the same two.
var attempts = 0
while true {
    attempts += 1
    continue if attempts < 3
    break
}
print("took #{attempts} attempts")

print()

# break affects the loop it is written in — the inner one here.
for row in 1..3 {
    for column in 1..3 {
        break if column > row
        print("(#{row}, #{column})")
    }
}

# A block is a function, so `break` inside one is a compile error rather than a
# surprise at runtime:
#
#     items.each { x => break }     # break cannot leave a block.
#
# Use a plain for loop when you need to stop early.
