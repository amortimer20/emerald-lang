struct Bag {
    var items: List[Int] = []

    @deprecated("Use `append` instead.")
    func push(item: Int) {
        self.items.append(item)
    }

    func append(item: Int) {
        self.items.append(item)
    }
}

var bag = Bag()
bag./*cursor*/
