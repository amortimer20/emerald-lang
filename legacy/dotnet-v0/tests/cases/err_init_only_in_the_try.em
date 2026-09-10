## The try assigns and the catch does not, so the path where the try threw partway
## reaches the end unassigned. The catch is where recovery has to include the field.
class OnlyInTheTry {
    var n: Int
    constructor() {
        try { self.n = 1 } catch e { print("oops") }
    }
}
