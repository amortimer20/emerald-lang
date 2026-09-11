# Functions, from section 7.

const passing_score = 60

func grade(score: Int): Int {
    if score >= 90 {
        return 1
    }
    else if score >= passing_score {
        return 2
    }
    return 3
}

func factorial(n: Int): Int {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}

func average(total: Int, count: Int) {
    return total / count
}

print(grade(95), grade(70), grade(40))
print(factorial(10))
print(average(250, 4))
