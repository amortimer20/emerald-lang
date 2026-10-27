enum Box[Item] {
    empty
    full(item: Item)
}

var box: Box[Int] = Box.full(1)
box = Box.full("one")
