## Everything in `scoring/` belongs to the `Scoring` namespace, whether it is
## written in one file or ten. `main.em` reaches these either by writing
## `Scoring.total(...)` or, as it does, by saying `using Scoring` once.

## A module-level value. It is worked out the first time anything in this file
## is used, not when the program starts.
const pass_mark = 5

func total(scores: List[Int]): Int {
    var sum = 0
    scores.each { score => sum += score }
    return sum
}

func best(scores: List[Int]): Int {
    var highest = 0
    scores.each { score => highest = score if score > highest }
    return highest
}

func average(scores: List[Int]): Int {
    return 0 if scores.count == 0
    return total(scores) // scores.count
}
