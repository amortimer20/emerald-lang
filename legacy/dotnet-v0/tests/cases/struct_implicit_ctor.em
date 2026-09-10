## A struct with no constructor gets one from its fields, in declaration order.
struct Vector3 with Addable {
    var x: Float
    var y: Float
    var z: Float

    func add(other: Vector3): Vector3 {
        return Vector3(self.x + other.x, self.y + other.y, self.z + other.z)
    }

    func to_string(): String { return "(#{self.x}, #{self.y}, #{self.z})" }
}

print(Vector3(1.0, 2.0, 3.0).to_string())
print((Vector3(1.0, 2.0, 3.0) + Vector3(0.5, 0.5, 0.5)).to_string())

## An explicit constructor still wins — it is not merely a default that gets merged.
struct Celsius {
    var degrees: Float
    constructor(fahrenheit: Float) {
        self.degrees = (fahrenheit - 32.0) * 5.0 / 9.0
    }
    func to_string(): String { return "#{self.degrees}C" }
}

print(Celsius(212.0).to_string())
