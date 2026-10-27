func distinct[Item with Hashable](items: List[Item]): Int {
    return items.to_set().count
}

func count_of[Value with Equatable](items: List[Value]): Int {
    return distinct(items)
}
