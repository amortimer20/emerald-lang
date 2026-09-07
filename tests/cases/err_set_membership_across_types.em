## Comparing an Int with a Float is fine; looking one up among the other is not.
##
## == converts, because a comparison can. A set and a dictionary find a value by hashing
## it, and a long and a double do not hash alike -- so admitting the mixed case would put
## back the same disagreement in the one place it cannot be papered over. The checker
## refuses the question instead, which keeps int_and_float_are_one_number_line true
## without a hash that has to lie.
var numbers = [1, 2].to_set()
print(numbers.contains?(1.0))

var scores = [1: "one"]
print(scores.get(1.0))
print(scores.has?(1.0))
