# Mistake: assigning to a character of a string (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices) (str immutable).
var name = "ava"
name[0] = "A"
print(name)
