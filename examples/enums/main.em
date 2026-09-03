# Enums: a closed set of named values (§6)
#
# The alternative is passing strings around, which loses every bit of checking — the one
# thing the type system exists for. `align("centre")` compiles and then does nothing;
# `align(Alignment.CENTER)` cannot be spelled wrong.

enum Alignment { LEFT, CENTER, RIGHT }

enum Suit {
    HEARTS,
    DIAMONDS,
    CLUBS,
    SPADES
}

# Values are constants of their own type, so they take §3.4's constant casing — the same
# rule that governs MAX_SCORE, with nothing new to learn.

var side = Alignment.CENTER
print(side)
print(side.name)
print(side.name.lower())

print()
print("centred? #{side == Alignment.CENTER}")
print("left?    #{side == Alignment.LEFT}")

# Every value, in declaration order.
print()
for suit in Suit.values {
    print("  #{suit.name}")
}
print("#{Suit.values.count} suits")

# The point: a function that takes one cannot be handed anything else. A misspelled
# string would have compiled and misbehaved at runtime.
func margin_for(a: Alignment): Int {
    return if a == Alignment.CENTER then 0 else 8
}

print()
print("centre margin: #{margin_for(Alignment.CENTER)}")
print("right margin:  #{margin_for(Alignment.RIGHT)}")

# An enum value is an ordinary value — it goes in lists, dictionaries, and sets.
var red_suits = [Suit.HEARTS, Suit.DIAMONDS]
print()
print("red suits: #{red_suits.count}")

var seen: Set<String> = [].to_set
for suit in Suit.values {
    seen.add(suit.name)
}
print("names remembered: #{seen.count}")

# What an enum is not, in v0: it has no payload and no methods. A closed set of names is
# what the demand was, and a tagged union is a different feature wearing the same word.
#
# There is also no exhaustiveness check, because there is nothing to be exhaustive over —
# `case`/`when` is deferred in §6, and enums are the strongest argument yet for it.
