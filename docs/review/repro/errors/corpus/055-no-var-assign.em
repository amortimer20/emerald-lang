# Mistake: assigning without declaring (Python habit) (line 2). Source: carry-over from Python; Kohn 2019 (The Error Behind the Message, Python novices).
total = 0
total += 5
print(total)
