func first_or[Item](items: List[Item], fallback: Item): Item {
    return if items.empty?() then fallback else items[0]
}

print(first_/*cursor*/or([1], 0))
