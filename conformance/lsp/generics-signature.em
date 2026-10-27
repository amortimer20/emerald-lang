func largest[Item with Ordered](items: List[Item]): Item? {
    return items.max()
}

print(largest([/*cursor*/3]))
