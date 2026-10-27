enum Chain[Item] {
    end
    link(item: Item, rest: Chain[Item])
}

const chains: Set[Chain[Int]] = []
