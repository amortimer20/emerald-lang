## An enum value is a name from a closed set. Nothing about it can change and two of the
## same name are the same value, so it needs nothing at all to be a sound member.
enum Suit { HEARTS, SPADES }

var seen = [Suit.HEARTS, Suit.SPADES, Suit.HEARTS].to_set()
print(seen.count())
print(seen.contains?(Suit.SPADES))
