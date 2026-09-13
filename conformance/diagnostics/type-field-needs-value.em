# Section 10.4: type-level fields "require initial values", and a type-level
# computed property is not part of the design.
struct Player {
    var Player.count: Int
    const Player.total: Int {
        return 0
    }
}
