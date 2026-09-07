## A block lambda's returns are now checked against the type the position asks for.
##
## They were not before: a multi-statement lambda was typed as giving back Unknown, so
## its returns were checked against nothing at all and any value passed. The type it is
## being assigned to is the only thing that can say what those returns must be, since a
## block has no single expression to read a type from.
var f: func(): Int = {
    var x = 5
    return "not an int"
}
