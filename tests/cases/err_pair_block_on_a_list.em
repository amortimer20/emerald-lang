## `(a, b)` takes a pair apart, and a list hands over one element that is not one. Caught
## rather than left to bind the second name to nothing, which is the silent nothing §3.2's
## whole design exists to make impossible — and the message names the form that does fit
## rather than only the one that does not.

var numbers = [1, 2, 3]

numbers.each { (first, second) =>
    print(first)
}
