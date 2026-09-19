const factor = 3

func apply(values: List[Int], block: func(Int): Int): List[Int] {
    return values.map(block)
}

func triple(value: Int): Int {
    return value * factor
}
