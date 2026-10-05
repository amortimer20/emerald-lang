func inner(value: Int): Int {
    return value
}
func outer(value: Int) {
}
outer(/*cursor*/inner(1))
