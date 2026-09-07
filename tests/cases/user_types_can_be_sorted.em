## A type that says how it orders is ordered everywhere, not only by the operators.
##
## `<` asked the class for its compare method; sorting went through a comparer that knew
## about numbers and strings and nothing else. So `Money(1) < Money(2)` answered, and
## `[Money(3), Money(1)].sort()` died inside the host's sort with "the compiler hit a
## problem it did not expect -- this is a bug in Emerald, not in your program". Which was
## unreadable and, worse, untrue: the program was fine and the answer was reachable.
##
## Both now go through the same CLR method the type implements, so an operator and a sort
## cannot disagree about the same two values. It is the same fix as sort disagreeing with
## < over strings, arriving from the other side: one rule, reached by one route.

class Money with Ordered, Equatable {
    var cents: Int
    constructor(cents: Int) { self.cents = cents }
    func compare(other: Money): Int { return self.cents - other.cents }
    func equals?(other: Money): Bool { return self.cents == other.cents }
    func to_string(): String { return "$#{self.cents}" }
}

print(Money(1) < Money(2))
print(Money(2) <= Money(2))
print(Money(3) > Money(1))

print([Money(3), Money(1), Money(2)].sort())
print([Money(3), Money(1)].min())
print([Money(3), Money(1)].max())
print([Money(3), Money(1), Money(2)].sort_by { m => m.cents })
print([Money(3), Money(1)].max_by { m => m.cents })
