# JSON: encoding records to text and decoding them back.

struct Item {
    const name: String
    const price: Float
    const tags: List[String]
}

var items: List[Item] = []
for index in 0..<4000 {
    items.append(Item("item #{index}", index.to_float() / 4, ["tag#{index % 7}", "tag#{index % 3}"]))
}
var total = 0.0
for _ in 0..<40 {
    const text = Json.encode(items)
    const decoded = Json.decode(text, as: List[Item])
    total += decoded[decoded.count - 1].price
}
print(total)
