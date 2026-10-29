# Section 10.4: a type-level field is one binding any function may change, so a test
# against `nothing` does not narrow it.
class Session {
    var Session.current: String? = nothing
}

func greet(): String {
    if Session.current != nothing {
        return Session.current
    }
    return "nobody"
}
