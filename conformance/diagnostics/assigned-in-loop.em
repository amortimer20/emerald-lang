# A loop body may run zero times, so a name it assigns is not known to be
# assigned after the loop.

var last: Int
for number in 1..3 {
    last = number
}
print(last)
