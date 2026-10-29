# Mistake: to_int on a decimal string (line 3). Source: Kohn 2019 (The Error Behind the Message, Python novices) (ValueError).
var price = "3.50"
var n = price.to_int()
print(n)
