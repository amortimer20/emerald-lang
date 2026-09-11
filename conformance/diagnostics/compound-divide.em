# Section 5.3 lowers `/=` through `/`, and `/` always produces a Float. A name
# holding an Int therefore cannot hold the result, which is worth explaining
# because the cause is two rules away from the line that fails.

var count = 10
count /= 2
