# An assignment starts from a name. A call's result is kept in a name first,
# which for an object reaches the same object.

class Counter {
    var count: Int = 0
}

func counter(): Counter {
    return Counter()
}

counter().count += 1
