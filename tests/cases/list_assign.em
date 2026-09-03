## Writing a list element. This did not work at all until Indexable landed —
## the checker accepted it and the interpreter refused it.
var a = [1, 2, 3]
a[0] = 99
a[1] += 10
print(a.join(", "))

var words = ["one", "two"]
words[1] = "TWO"
print(words.join(" "))
