# Section 14.3: an enum's nested types come after its values.
enum Suit {
    struct Label {
        const text: String
    }

    hearts
    spades
}
