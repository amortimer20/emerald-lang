# Section 3.3: names use Unicode's identifier characters, and canonically
# equivalent spellings are the same name. The second `café` below is
# written with `e` and a combining accent, U+0301, rather than the single
# precomposed character the first one uses.

var über = 1
var 字 = 2
var café = 3
print(über + 字 + café)
