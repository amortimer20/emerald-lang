# Section 8.4: statically known duplicate keys are literals and enum values. A repeated
# tuple of literals is not one, so it behaves as colliding calculated keys do: the later
# value wins in the first entry's position.
const pairs = [(1, 2): "first", (3, 4): "middle", (1, 2): "second"]
print(pairs)
