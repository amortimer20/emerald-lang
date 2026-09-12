const factor = 3

func apply(values: [Int], block: func(Int): Int): [Int] {
    return values.map(block)
}

func triple(value: Int): Int {
    return value * factor
}
