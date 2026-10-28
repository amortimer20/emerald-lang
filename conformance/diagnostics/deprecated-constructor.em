struct Spot {
    var x: Int

    @deprecated("Use `Spot.at` instead.")
    constructor(x: Int) {
        self.x = x
    }
}
