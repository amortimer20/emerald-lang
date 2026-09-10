func best(scores: List<Int>): Int {
    return scores.find { s => s > 100 }
}
