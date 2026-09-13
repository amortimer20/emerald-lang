# Section 7.2's rule against circular inference reaches through a type-level
# field whose value calls a function that reads it.
struct Tally {
    var Tally.total = Tally.next()

    func Tally.next() {
        return Tally.total + 1
    }
}
