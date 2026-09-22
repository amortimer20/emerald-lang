# A type's name is not a value, and how to get a value depends on what kind
# of type it is.
struct Point {
    const x: Int
}

trait Named {
    const name: String
}

enum Suit {
    hearts
    spades
}

print(Point)
const contract = Named
const suit = Suit
const ordering_contract = Ordered
