struct Bag {
    var items: List[Int] = []

    ## Adds one item.
    @deprecated("Use `append` instead.")
    func push(item: Int) {
        self.items.append(item)
    }
}

var bag = Bag()
bag.pu/*cursor*/sh(3)
