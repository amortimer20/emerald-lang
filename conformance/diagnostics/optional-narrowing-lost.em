# Section 4.5: a `var` a block can reassign cannot be proved present, because
# calling the block is all it takes to change it back.
var score: Int? = 5
const clear = { => score = nothing }
if score != nothing {
    clear()
    print(score + 1)
}
