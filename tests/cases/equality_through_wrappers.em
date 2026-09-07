## Adversarial: one type's equals? has to survive every wrapper the language can put a
## value inside. Each of these reaches the same user-written equals? by a different route,
## and disagreement between any two of them is a bug even though each route was tested
## on its own.
##
## This combination is how the Pair bug was found: == worked, Pair(a, b) == Pair(a, b)
## did not, and no single-feature test could see it because each feature worked alone.

class Money with Equatable {
    var cents: Int
    constructor(cents: Int) { self.cents = cents }
    func equals?(other: Money): Bool { return self.cents == other.cents }
    func to_string(): String { return "$#{self.cents}" }
}

var a = Money(5)
var b = Money(5)

print(a == b)                              # bare
print([a].contains?(b))                    # list search
print([a].index_of(b) == 0)                # list search, by position
print([a] == [b])                          # list equality, elementwise
print(Pair(a, 1) == Pair(b, 1))            # inside a pair
print([Pair(a, 1)].contains?(Pair(b, 1)))  # a pair inside a list
print([[a]].contains?([b]))                # a list inside a list
print(["k": a] == ["k": b])                # a dictionary value

## And the negative half: a difference has to survive the same wrappers, or the routes
## agree only by always saying true.
var c = Money(6)
print(a == c)
print([a].contains?(c))
print(Pair(a, 1) == Pair(c, 1))
print([[a]].contains?([c]))
print(["k": a] == ["k": c])

## A set and a dictionary key still cannot hold one -- lookup hashes, and hashing cannot
## consult equals? yet. That is checked, not silent: see err_struct_cannot_be_a_key.
