print([1, 2, 3].chain([4, 5]))
print([1, 2, 3, 4].chunks(2))
print([1, 2, 3, 4].windows(2))
print([1, 2, 3].pairs())

# An empty or single-element list has no adjacent pair to report.
const empty: List[Int] = []
print(empty.pairs())
print([1].pairs())
