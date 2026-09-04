## Checked at the use site, which is the reason visibility is spelled in the name: the
## reader sees it where the call is written, without going to look the declaration up.
class Circle {
    var radius: Float

    constructor(radius: Float) { self.radius = radius }

    func _squared(): Float { return self.radius * self.radius }
}

print(Circle(2.0)._squared())
