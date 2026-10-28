# Mistake: using a / result as a list index (line 3). Source: review brief list (integer division surprise).
var scores = [3, 7, 9, 12, 15]
var middle = scores[scores.count / 2]
print(middle)
