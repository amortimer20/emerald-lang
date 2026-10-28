# Mistake: summing numbers read as text (line 5). Source: Kohn 2019 (The Error Behind the Message, Python novices).
var parts = "1,2,3".split(",")
var total = 0
for p in parts {
    total += p
}
print(total)
