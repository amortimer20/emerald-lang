# 8.4 fixes insertion order for sets but not the order of a set built by
# union, intersection, difference, or symmetric_difference.
# conformance/run/set-operations.expected encodes the receiver-first choice.
const a: Set[Int] = [3, 1, 2]
const b: Set[Int] = [2, 4, 3]
print(a.union(b), b.union(a))
print(a.intersection(b), b.intersection(a))
print(a.symmetric_difference(b), b.symmetric_difference(a))
