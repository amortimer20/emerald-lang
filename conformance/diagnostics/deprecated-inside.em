@deprecated("Use `newer` instead.")
func old() {
}

@deprecated("Use `newest` instead.")
func older() {
    old()
}

@deprecated("Use `Point` instead.")
const origin: Spot = Spot(0)

@deprecated("Use `Point` instead.")
struct Spot {
    var x: Int

    func moved(): Spot {
        return Spot(self.x + 1)
    }
}

func newer() {
    old()
}
