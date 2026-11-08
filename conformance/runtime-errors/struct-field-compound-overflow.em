# Section 5.3: `+=` on a struct field overflows like any addition, and
# points at the field it changes.

struct Tally {
    var count: Int
}

var tally = Tally(9223372036854775807)
tally.count += 1
