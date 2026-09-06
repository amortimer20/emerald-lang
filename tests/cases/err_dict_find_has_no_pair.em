# A dictionary walks in pairs, and Emerald has no tuple type -- so the members that
# hand an element back are refused with the route that does exist.

var scores = ["ada": 90]
print(scores.find { name, score => score > 50 })
