## Ordinary arithmetic is untouched — the check only fires where the answer does not fit.
print(2 + 2)
print(1000000 * 1000000)
print(0 - 9223372036854775807)

var big = 9223372036854775807
var n = 0

## Each of the three reports rather than wrapping. Caught, so the program can go on and
## show all of them.
try { n = big + 1 } catch e { print(e.message()) }
try { n = (0 - big) - 2 } catch e { print(e.message()) }
try { n = big * 2 } catch e { print(e.message()) }
try { n = big ** 2 } catch e { print(e.message()) }
