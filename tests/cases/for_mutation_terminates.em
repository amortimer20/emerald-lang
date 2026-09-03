## Adding to a list while walking it must not loop forever. The walk is over the
## items that were there when it started.
var xs = [1, 2]
for x in xs { xs.add(x) }
print(xs.join(","))
