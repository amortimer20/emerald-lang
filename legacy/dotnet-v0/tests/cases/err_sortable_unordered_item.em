## Claiming Sortable for items that have no order. Refused at the declaration that made
## the claim rather than at the call that would trip over it, so the message points at the
## line a reader can act on — and it names the fix in both directions, since either giving
## Card an order or dropping the claim is a reasonable thing to want.

class Card {
    var name: String
    constructor(name: String) { self.name = name }
}

class Deck with Sortable {
    type Item = Card

    func each(step: func(Card)) {
        step(Card("Ace"))
    }
}

print(Deck().max().must().name)
