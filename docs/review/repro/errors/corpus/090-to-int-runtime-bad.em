# Mistake: to_int on text that is not a number (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices) (ValueError).
var text = "twelve"
var n = text.to_int()
print(n)
