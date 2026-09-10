## min and max need an order, which walking alone cannot give — so they live on a trait
## mixed in beside Iterable rather than on Iterable itself. Most collections have no order
## and should not be made to invent one: a deck of cards walks perfectly well without being
## sortable, and the case next door proves the claim is checked rather than assumed.
##
## `type Item: Ordered` refines what Iterable already declared. The name stays Iterable's;
## this says what an answer to it has to be, and it sits beside the name rather than
## trailing the declaration in a clause.

class Scores with Sortable {
    type Item = Int

    func each(step: func(Int)) {
        step(7)
        step(2)
        step(9)
    }
}

var scores = Scores()
print(scores.max().or(0))
print(scores.min().or(0))

## Still an Iterable in every other respect, since that is what Sortable mixes in.
print(scores.count())
print(scores.filter { n => n > 5 }.join(", "))
print(scores.contains?(2))

## A type of your own qualifies by having an order, not by being built in.
class Card with Ordered {
    var name: String
    var value: Int

    constructor(name: String, value: Int) {
        self.name = name
        self.value = value
    }

    func compare(other: Card): Int {
        return self.value - other.value
    }
}

class Deck with Sortable {
    type Item = Card

    func each(step: func(Card)) {
        step(Card("Ace", 1))
        step(Card("King", 13))
        step(Card("Seven", 7))
    }
}

print(Deck().max().must().name)
print(Deck().min().must().name)
