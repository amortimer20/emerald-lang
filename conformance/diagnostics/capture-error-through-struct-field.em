struct Bag {
    var values: List[Int]
}

var later: Int
func pick(): Int {
    return later
}

var grid = [Bag([1])]
grid[pick()].values.append(1)
later = 0
