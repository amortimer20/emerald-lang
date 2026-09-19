# Section 4.4: lists are invariant. An Int list is not a Float list, because
# its elements would have to change type to become one. A literal can still be
# built as a Float list, since it has no elements yet when it gets its type.

var whole = [1, 2]
var fractional: List[Float] = [1, 2]
var mistaken: List[Float] = whole
