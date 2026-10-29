# Mistake: storing / result in an Int (line 4). Source: review brief list (integer division surprise); guide docs/language/core.md.
var total = 10
var count = 4
var average: Int = total / count
print(average)
