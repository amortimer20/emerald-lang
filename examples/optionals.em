# A value that may be absent is marked with `?`, and the language makes you say
# what happens when it is.
#
#     emerald run examples/optionals.em

const entries = ["12", "seven", "30", "", "8"]

# `to_int_maybe` reports "that is not a number" as absence rather than an error.
# `.or(...)` supplies what to use instead.
const scores = entries.map { entry => entry.to_int_maybe().or(0) }
print(scores)

# Or check first. Inside the `if`, `parsed` is known to be there, so it can be
# used as an ordinary Int.
var total = 0
var counted = 0
entries.each { entry =>
    const parsed = entry.to_int_maybe()
    if parsed != nothing {
        total += parsed
        counted += 1
    }
}
print("#{counted} of #{entries.count} entries were numbers, adding to #{total}")

# `first`, `last`, and `find` may all come back empty-handed.
print(scores.first.or(-1))
print(scores.find { score => score > 20 }.or(-1))
print(scores.find { score => score > 900 }.or(-1))

# A guard reads well and narrows everything below it.
func describe(entry: String?): String {
    return "nothing at all" if entry == nothing
    return "empty text" if entry.empty?()
    return "the number #{entry}" if entry.to_int_maybe() != nothing
    return "the word #{entry}"
}

print(describe("12"))
print(describe("seven"))
print(describe(""))
print(describe(nothing))

# `index_of` answers with a position, and the position is absent when the text
# is not there at all.
const sentence = "the quick brown fox"
print(sentence.index_of("brown").or(-1))
print(sentence.index_of("cat").or(-1))
