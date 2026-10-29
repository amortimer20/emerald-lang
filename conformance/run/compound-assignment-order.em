# Section 5.2: compound assignment evaluates its receiver and index, reads the current
# value, then evaluates the right side; every subexpression runs at most once.
var scores = [10, 20, 30]

func position(): Int {
    print("index")
    return 1
}

func amount(): Int {
    print("amount, scores[1] is #{scores[1]}")
    scores[1] = 100
    return 5
}

scores[position()] += amount()
print(scores)
