# Sections 10.3 and 10.4: a type's members share one set of names, whichever
# of them belong to the type.
struct Player {
    var count: Int
    var Player.count = 0

    func Player.create(): Player {
        return Player(0)
    }

    func create() {
    }
}
