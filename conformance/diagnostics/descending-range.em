# Section 6.4: ranges count upward, so a range written with descending literal
# endpoints can only be empty, which can only be a mistake.

for number in 10..1 {
    print(number)
}
