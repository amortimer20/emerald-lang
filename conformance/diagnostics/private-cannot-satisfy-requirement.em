# Section 11.1: private members cannot satisfy public requirements.
trait Named {
    const name: String

    func greet(): String
}

struct Robot with Named {
    const _name: String = "R2"

    @override
    func _greet(): String {
        return "beep"
    }
}
