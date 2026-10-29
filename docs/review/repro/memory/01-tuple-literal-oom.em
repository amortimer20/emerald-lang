# A tuple literal whose tuple allocation fails: Heap.createTuple frees
# `items` and `kinds`, then evaluateTuple's errdefer releases and frees them
# again. Run under the allocation-failure harness (see memory.md, finding 1).
const pair = ("score", 10)
print(pair)
