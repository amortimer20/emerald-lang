# Mistake: subtracting strings (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices).
var word = "hello!"
var clean = word - "!"
print(clean)
