# Section 15.4's regular expressions: a pattern, written as a single-quoted
# string so its backslashes stay as they are, checked against text.
const ticket = Regex('[A-Z]{3}-\d{4}')
print(ticket.matches?("ABC-1234"), ticket.matches?("ABC-12345"), ticket.matches?("abc-1234"))
print(ticket.contains_match?("see ABC-1234 and DEF-5678"), ticket.contains_match?("none here"))

# `find` gives the first match or nothing; positions count characters, as
# indexing does.
const note = "Due 9/25/2026"
const first = Regex('\d+').find(note)
print(first, Regex('x').find(note))
if first != nothing {
    print(first.text, first.start, first.end, note[first.start..<first.end])
}

# `find_all` goes from left to right, and matches never overlap.
const numbers = Regex('\d+').find_all("3 apples, 12 pears, 7 plums").map { found => found.text.to_int() }
print(numbers, numbers.sum())
print(Regex('aa').find_all("aaaaa"))

# Repetition takes as many as it can, or with ? as few as it can; the first
# alternative that matches wins.
print(Regex('<.+>').find("<a><b>"), Regex('<.+?>').find("<a><b>"))
print(Regex('cat|category').find("category"), Regex('category|cat').find("category"))

# Anchors and word boundaries.
print(Regex('^\w+').find_all("one two\nthree four"), Regex('\w+$').find_all("one two\nthree four"))
print(Regex('\bcat\b').find_all("cat concat cat's bobcat"))

# A Regex is a value: it prints as its pattern and compares by pattern and
# options, so it can be a dictionary key.
const words = Regex('\w+')
print(words, words == Regex('\w+'), words == Regex('\w+', ignore_case: true), words.pattern)
var uses = [words: 1]
uses[Regex('\w+')] = 2
print(uses.count, uses[words])

# `Regex.escape` turns any text into a pattern that matches exactly it.
const price = Regex.escape("$4.99 (each)")
print(price, Regex(price).matches?("$4.99 (each)"), Regex(price).matches?("$4X99 (each)"))
