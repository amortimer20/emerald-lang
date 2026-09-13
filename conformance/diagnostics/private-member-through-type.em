# From outside the type, a private instance member reached through the type is
# reported as private, since reaching it through a value would fail too.
struct Counter {
    var _count: Int = 0

    func _bump() {
    }
}

print(Counter._count)
Counter._bump()
