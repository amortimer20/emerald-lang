# The branch prints and carries on, so nothing is proved below it.
func size_of(text: String): Int {
    var n = text.to_int_maybe()
    if n == nothing { print("no number") }
    return n.abs()
}
