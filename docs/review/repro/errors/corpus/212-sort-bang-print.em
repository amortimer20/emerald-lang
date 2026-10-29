# Mistake: printing the result of sort!() (line 3). Source: carry-over from Python (print(xs.sort()) is None).
var scores = [3, 1, 2]
print(scores.sort!())
