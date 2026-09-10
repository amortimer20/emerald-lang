## A container's methods have no signature table, so their arguments are checked where
## the container's own key and value types are known.
var ages = ["ada": 36]
print(ages.has_key?(7))
