const _scale = 10

struct Circle {
    const radius: Int
    var area: Int

    constructor(radius: Int) {
        self.radius = radius
        self.area = radius * radius * _scale
    }
}

# Constructed while this file is still being set up, which only needs the
# private value declared above it.
const unit = Circle(1)
