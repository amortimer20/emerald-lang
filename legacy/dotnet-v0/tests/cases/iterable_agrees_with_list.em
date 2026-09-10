## The trait and the built-in containers answer the same questions, so they have to give
## the same answers. `contains?` did not. Iterable built it on `find`, which reports a miss
## by handing back nothing — indistinguishable from finding a nothing that is really there,
## the moment Item is itself nullable. A bag holding nothing said it did not hold it, while
## the list beside it said it did: one question, two answers, decided by which family the
## method was inherited from.
##
## Pinned here rather than left to the two implementations agreeing by luck, since there is
## no shared source for them to agree through — the built-ins are native and the trait is
## Emerald.

class Bag with Iterable {
    type Item = String?

    var things: List<String?>

    constructor(things: List<String?>) {
        self.things = things
    }

    func each(step: func(String?)) {
        for thing in self.things {
            step(thing)
        }
    }
}

var absent: String? = nothing
var held: List<String?> = ["ada", absent]
var bag = Bag(held)

## The ordinary questions, which were never in doubt.
print(bag.contains?("ada"))
print(held.contains?("ada"))
print(bag.contains?("nobody"))
print(held.contains?("nobody"))

## And the one that was: a collection holding nothing says so, whichever family is asked.
print(bag.contains?(nothing))
print(held.contains?(nothing))

## The rest of what both families answer to, pinned so they cannot drift apart either.
print(bag.count() == held.count())
print(bag.to_list().count() == held.count())
print(bag.filter { thing => thing != nothing }.count())
print(held.filter { thing => thing != nothing }.count())
