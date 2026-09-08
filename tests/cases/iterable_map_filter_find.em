## A user class earns map, filter, find, count, to_list and contains? by writing each once
## and mixing in Iterable -- the same trick List, Dictionary and Set have built in.
class Card {
    var name: String
    var value: Int
    constructor(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}

class Deck with Iterable {
    type Item = Card
    var cards: List<Card>

    constructor(cards: List<Card>) { self.cards = cards }

    func each(step: func(Card)) {
        for c in self.cards { step(c) }
    }
}

var deck = Deck([Card("Ace", 1), Card("King", 13), Card("Queen", 12)])

## R is never written -- map's own return type says List<R>, and this is what infers it.
var names = deck.map { c => c.name }
print(names.join(", "))

var high_cards = deck.filter { c => c.value > 10 }
print(high_cards.count())

var found = deck.find { c => c.name == "King" }
print(found?.name.or("none"))

print(deck.count())
print(deck.to_list().count())
