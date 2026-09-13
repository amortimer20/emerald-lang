var scale: Int

struct Length {
    var units: Int

    const scaled: Int {
        return self.units * scale
    }
}

var length = Length(2)
print(length.scaled)
scale = 3
