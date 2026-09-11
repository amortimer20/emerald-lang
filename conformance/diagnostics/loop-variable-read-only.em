# Section 6.4: loop bindings are read-only and fresh for every iteration.

for number in 1..3 {
    number = number * 2
}
