## max_by and min_by live on Iterable rather than on Sortable, and the reason is the point:
## what has to have an order is K, the block's answer, not Item. A deck of cards with no
## order of its own still has a highest card by value.
##
## `<K: Ordered>` is the same constraint written in the other place it can appear — beside
## a method's own type parameter instead of beside an associated type.

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

    func each(step: func(Card)) {
        step(Card("Ace", 1))
        step(Card("King", 13))
        step(Card("Seven", 7))
    }
}

var deck = Deck()

print(deck.max_by { c => c.value }.must().name)
print(deck.min_by { c => c.value }.must().name)

## Ranked by a String instead, which is ordered for the same reason a number is.
print(deck.max_by { c => c.name }.must().name)
print(deck.min_by { c => c.name }.must().name)

## The list beside it answers the same way.
var values = [1, 13, 7]
print(values.max_by { n => n })
print(values.min_by { n => n })

## Nothing to rank gives nothing back, on both.
class Empty with Iterable {
    type Item = Int
    func each(step: func(Int)) { }
}

print(Empty().max_by { n => n } == nothing)
print([].max_by { n => n } == nothing)
