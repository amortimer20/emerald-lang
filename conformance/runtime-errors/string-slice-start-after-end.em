# Section 5.4: a string slice whose start is after its end is an error too.
const text = "hello"
const start = 4
print(text[start..2])
