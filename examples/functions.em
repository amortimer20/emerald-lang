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

# A parameter with a default can be left out, and a named argument can skip
# straight past it to one further along.
func label(score: Int, prefix: String = "Score", suffix: String = "") {
    print("#{prefix}: #{score}#{suffix}")
}

label(88)
label(88, "Final")
label(88, suffix: " points")

# A function can be declared inside another. It can be called anywhere in the
# block around it, even above where it is written, and it shares that block's
# variables, as a lambda does.
func summarize(scores: List[Int]): String {
    var total = 0
    for score in scores {
        add(score)
    }
    return "#{scores.count} scores, #{total} in all"

    func add(score: Int) {
        total += score
    }
}

print(summarize([88, 92, 75]))
