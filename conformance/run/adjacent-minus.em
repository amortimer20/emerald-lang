# Repeated minus signs are subtraction/negation, not decrement.
const c = 3
print(c--1, --c, c - -1)
const continued = c--
    1
print(continued)
var changed = c
changed += 1
changed -= 1
print(changed)
