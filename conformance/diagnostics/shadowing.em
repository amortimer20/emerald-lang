# Section 6.1 rejects shadowing a visible local within the same function,
# because the writer usually meant assignment. A block does not escape the rule.

var score = 1

if true {
    var score = 2
    print(score)
}
