# A range counts up and only up. Its ends the other way round make it empty, rather than
# reversing it - which is what makes 0..(n - 1) safe, the only spelling an inclusive
# range has for "walk n items".

var empty: List<String> = []

for i in 0..(empty.count() - 1) {
    print("this must not run: #{i}")
}
print("walked an empty list")

var items = ["a", "b", "c"]
for i in 0..(items.count() - 1) {
    print("#{i}: #{items[i]}")
}

# Ends the other way round, worked out rather than written down.
var high = 5
var low = 1

print("count:    #{(high..low).count()}")
print("contains: #{(high..low).contains?(3)}")

var walked = 0
for i in high..low {
    walked += 1
}
print("walked:   #{walked}")

# upto and downto each mean their own direction. Both used to build a range and walk it,
# so the range decided and neither name meant anything: 3.upto(1) counted down.
print("3.upto(5):")
3.upto(5) { n => print("  #{n}") }

print("3.upto(1): (nothing)")
3.upto(1) { n => print("  #{n}") }

print("5.downto(1):")
5.downto(1) { n => print("  #{n}") }

print("5.downto(9): (nothing)")
5.downto(9) { n => print("  #{n}") }
