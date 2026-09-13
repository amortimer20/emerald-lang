const _standard = 4

struct Tile {
    var size: Int = _standard

    const area: Int {
        return self.size * self.size
    }
}
