enum Box[Item] {
    empty
    full(item: Item)
}

func size(box: Box[String]): Int {
    return case box {
        when Box.empty then 0
        when Box.full(item) then item + 1
    }
}
