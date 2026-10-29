# Section 4.5: narrowing does not assume a mutable property stays unchanged between
# reads; binding it to a local makes the proof explicit.
class Box {
    var item: Int? = 3
}

func total(box: Box): Int {
    if box.item != nothing {
        return box.item + 1
    }
    const item = box.item
    if item != nothing {
        return item + 1
    }
    return 0
}
