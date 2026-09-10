## A list can be changed after it is stored, so what it holds cannot be part of how
## something is found again. This is the shape that stayed refused when objects and
## structs became keys: the hazard is the mutation, not the user type.
var seen: Dictionary<List<Int>, String> = [:]
print(seen.count())
