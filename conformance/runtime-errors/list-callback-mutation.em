var items = [3, 1, 2]
items.remove_if { item =>
    items.append(item)
    return false
}
