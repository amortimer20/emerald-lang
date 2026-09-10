# A block cannot name more than it is handed. Naming fewer is ordinary - ignoring an
# argument is allowed everywhere - but the extra names could only ever be nothing, and
# they were silently bound to the element type as though they held one.

var numbers = [1, 2, 3]
print(numbers.map { a, b => a }.join(","))
