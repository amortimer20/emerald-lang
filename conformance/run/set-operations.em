const left: {Int} = [1, 2, 3]
const right: {Int} = [3, 4]
const other: {Int} = [2, 4]
const small: {Int} = [1, 2]
const full: {Int} = [1, 2, 3]
const separate: {Int} = [3, 4]

print(left.union(right))
print(left.intersection(other))
print(left.difference(other))
print(left.symmetric_difference(other))
print(small.subset?(full))
print(full.superset?(small))
print(small.disjoint?(separate))
