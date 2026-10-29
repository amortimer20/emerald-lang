# Section 8.6: set operations use names; comparison operators do not stand for subset.
const small: Set[Int] = [1]
const large: Set[Int] = [1, 2]
print(small < large)
print(small <= large)
print(small.subset?(large))
