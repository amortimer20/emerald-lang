# Mistake: appending to a list parameter (line 3). Source: guide docs/language/core.md.
func add_bonus(scores: List[Int]) {
    scores.append(10)
}
var mine = [1, 2]
add_bonus(mine)
print(mine)
