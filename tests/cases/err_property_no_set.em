class Circle {
    var radius: Float = 1.0
    var area: Float {
        get { return 3.14 * self.radius * self.radius }
    }
}
var c = Circle()
c.area = 9.0
