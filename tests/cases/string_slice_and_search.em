# A substring without integer indexing: §3.2 keeps strings out of the index syntax
# because grapheme indexing is O(n) wearing O(1)'s clothes. A method promises nothing
# about cost, so the same operation is honest.

print("hello world".slice(0, 5))
print("hello world".slice(6))
print("hello".slice(-3, 2))

# Counted in graphemes, so a family emoji comes back whole
print("héllo👩‍👩‍👧!".slice(5, 1))

# Running off either end is the ordinary case, not a failure
print("hi".slice(0, 100))
print("hi".slice(50, 1) + "|")

print("hello".index_of("ll"))
print("hello".index_of("z"))

print("  hi  ".trim_start() + "|")
print("  hi  ".trim_end() + "|")
print("  hi  ".trim() + "|")

# The tail is left alone, so IBM survives having its first letter capitalized
print("mcdonald".capitalize())
print("IBM".capitalize())
print("".capitalize() + "|")
