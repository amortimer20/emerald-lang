# Condition hints must leave assignments inside predicate bodies alone.
var total = 0
if ([1, 2].any? { n =>
    total = n
    return n == 2
}) {
    print(total)
}
while total < 3 {
    total += 1
}
const accepted = if total == 3 then true else false
print(total, accepted)
print("guarded") if total == 3
assert total == 3
func guarded(): Int {
    return 4 if total == 3
    return 0
}
print(guarded())
