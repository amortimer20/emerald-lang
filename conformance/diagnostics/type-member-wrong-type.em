# Section 10.4: the type in front of a type-level member is the type it is
# written inside.
struct Counter {
    var value: Int
    var Count.start = 0

    func Countr.make(): Counter {
        return Counter(0)
    }
}
