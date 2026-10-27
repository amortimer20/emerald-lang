class Box[Item with Hashable] {
    var value: Item
}

const box: Box[List[Int]] = Box([1])
