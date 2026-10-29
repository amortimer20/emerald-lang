# 8.4: "A statically known duplicate dictionary literal key is an error".
# `[1: "a", 1: "b"]` is rejected, but literal tuple keys are not, so whether this
# program runs depends on what "statically known" covers.
const pairs = [(1, 2): "first", (1, 2): "second"]
print(pairs)
