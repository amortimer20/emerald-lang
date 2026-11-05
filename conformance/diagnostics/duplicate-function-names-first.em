# Section 7.3: a second declaration of a function name in one scope is an error naming
# the first.
func area(side: Int): Int {
    return side * side
}

func area(width: Int, height: Int): Int {
    return width * height
}
