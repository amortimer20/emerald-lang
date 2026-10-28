# Mistake: append a list instead of append_all (line 3). Source: carry-over from Python (append vs extend).
var scores = [1, 2]
scores.append([3, 4])
print(scores)
