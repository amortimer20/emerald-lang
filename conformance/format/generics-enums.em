enum Chain[ Item ] {
    end
    link(item:Item, rest:Chain[Item])
}
enum Pick[Item with Ordered] { nobody, one(item: Item) }
