## Tuples: a fixed group of values, each with its own type.
##
## A list holds many of one thing. A tuple holds a few things of different
## kinds, and its shape is part of its type: `(String, Int)` is always a name
## and a number, in that order.
##
## Run it with `emerald run examples/tuples.em`.

## The most useful thing a tuple does is let a function answer with more than
## one value, without inventing a type to carry them.
func divide(value: Int, by: Int): (Int, Int) {
    return (value // by, value % by)
}

const (whole, rest) = divide(17, 5)
print("17 / 5 is #{whole} remainder #{rest}")

## A tuple can be kept whole and reached by position, counting from zero.
const measured = ("width", 4.5)
print(measured)
print("#{measured.0} is #{measured.1}")

## A tuple is unpacked wherever names are introduced: a declaration, a `for`
## binding, or a block's parameters. `_` skips a position you do not need.
const readings = [("monday", 3), ("tuesday", 7), ("wednesday", 5)]

for (day, count) in readings {
    print("#{day}: #{count}")
}

var busiest = 0
readings.each { (_, count) => busiest = count if count > busiest }
print("busiest", busiest)

## Names that already exist can be assigned together. The whole right side is
## worked out before anything changes, so this really does swap them.
var first = "red"
var second = "blue"
(first, second) = (second, first)
print(first, second)

## A tuple inside a tuple unpacks in place, wherever names are unpacked.
const (label, (x, y)) = ("corner", (3, 4))
print(label, x + y)

## Tuples compare position by position, so two that were built separately are
## equal when their contents are.
print(("a", 1) == ("a", 1))
