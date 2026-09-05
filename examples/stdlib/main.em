# Math, and the string methods §3.2 promised

print("pi        #{Math.pi()}")
print("sqrt(2)   #{Math.sqrt(2.0)}")
print("2^10      #{Math.pow(2.0, 10.0)}")
print("min/max   #{Math.min(3, 9)} #{Math.max(3, 9)}")

# Strings are not integer-indexed — .chars is how you get characters, and it
# counts graphemes, so an emoji is one character rather than two UTF-16 units.
var word = "héllo 👋"
print("word      #{word}")
print("chars     #{word.chars().count()}")
print("first     #{word.chars().first().or("?")}")
print("reversed  #{word.chars().reverse().join("")}")

var csv = "ada,grace,alan"
print("split     #{csv.split(",").map { n => n.upper() }.join(" | ")}")
print("replace   #{csv.replace(",", " & ")}")

# Distance between two points, which is what Math exists for
var dx = 3.0
var dy = 4.0
print("distance  #{Math.sqrt(dx * dx + dy * dy)}")
