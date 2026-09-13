var score: Int? = 5

# Narrowed before the loop, but the body can set it back, so neither a later
# iteration nor the code after the loop may rely on it.
if score != nothing {
    var round = 0
    while round < 2 {
        print(score + 1)
        score = nothing
        round += 1
    }
    print(score + 1)
}

var bonus: Int? = 1
if bonus != nothing {
    for step in 1..3 {
        print(bonus + step)
        bonus = nothing if step == 2
    }
}
