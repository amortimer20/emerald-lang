# A body that promises a value has to produce one on every way out. Without this a
# function declared : Int could fall off its end and hand back nothing - which binds to a
# non-nullable Int and then fails somewhere else entirely, three lines from the cause.

func biggest(n: Int): Int {
    if n > 0 { return n }
}

func first_of(items: List<Int>): Int {
    for item in items { return item }
}

class Box {
    var kept: Int = 1

    func label(): String {
        if self.kept > 0 { print("something") }
    }

    var doubled: Int {
        get { print("working") }
    }
}
