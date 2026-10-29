# Section 10.3: the setter receives the proposed value through a read-only `value`.
struct Circle {
    var radius: Float

    var diameter: Float {
        get {
            return self.radius * 2
        }
        set {
            value = value + 1
            self.radius = value / 2
        }
    }
}
