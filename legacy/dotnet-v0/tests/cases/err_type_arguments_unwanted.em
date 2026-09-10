# Angle brackets on a call are for .NET's generic methods, which wait on the code
# generator. Nothing in Emerald's own surface takes them.

print([1].count<Int>())
