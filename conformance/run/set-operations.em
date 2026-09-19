const left: Set[Int] = [1, 2, 3]
const right: Set[Int] = [3, 4]
const other: Set[Int] = [2, 4]
const small: Set[Int] = [1, 2]
const full: Set[Int] = [1, 2, 3]
const separate: Set[Int] = [3, 4]

print(left.union(right))
print(left.intersection(other))
print(left.difference(other))
print(left.symmetric_difference(other))
print(small.subset?(full))
print(full.superset?(small))
print(small.disjoint?(separate))
