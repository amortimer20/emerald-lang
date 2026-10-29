# Section 7.1: function types reuse declaration syntax; `->` is not part of the
# callable surface.
const double: (Int) -> Int = { value => value * 2 }
