func first_or[Item](items: List[Item], fallback: Item): It/*cursor*/em {
    var best: Item = fallback
    return if items.empty?() then best else items[0]
}
