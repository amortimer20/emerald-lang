## A class that writes `each` now receives the vocabulary the built-ins share, not a third
## of it — which is the Ruby promise §3.7 makes and could not fund until associated types
## existed. Each answer is printed beside the list's own so the two cannot drift: there is
## no shared source through which they could agree by construction, one being native C#
## and the other Emerald in the prelude.
##
## `reject`, `take` and `drop` narrow, so they answer Filtered rather than List<Item> —
## the same reason `filter` does. A class that says nothing gets List, which is the only
## thing a trait can build.

class Deck with Iterable {
    type Item = Int

    var values: List<Int>

    constructor(values: List<Int>) {
        self.values = values
    }

    func each(step: func(Int)) {
        for value in self.values {
            step(value)
        }
    }
}

var deck = Deck([1, 2, 3, 4])
var list = [1, 2, 3, 4]

print("#{deck.any? { n => n > 3 }} #{list.any? { n => n > 3 }}")
print("#{deck.any? { n => n > 9 }} #{list.any? { n => n > 9 }}")
print("#{deck.all? { n => n > 0 }} #{list.all? { n => n > 0 }}")
print("#{deck.all? { n => n > 2 }} #{list.all? { n => n > 2 }}")
print("#{deck.empty?()} #{list.empty?()}")
print("#{Deck([]).empty?()} #{[].empty?()}")

print("#{deck.reject { n => n.even?() }.join(",")} #{list.reject { n => n.even?() }.join(",")}")
print("#{deck.take(2).join(",")} #{list.take(2).join(",")}")
print("#{deck.drop(2).join(",")} #{list.drop(2).join(",")}")

## Taking more than there is, and none at all — the edges where an off-by-one would show.
print("#{deck.take(99).count()} #{list.take(99).count()}")
print("#{deck.take(0).count()} #{list.take(0).count()}")
print("#{deck.drop(99).count()} #{list.drop(99).count()}")

deck.each_with_index { n, i => print("#{i}:#{n}") }
list.each_with_index { n, i => print("#{i}:#{n}") }
