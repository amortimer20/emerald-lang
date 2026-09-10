# Structs are immutable value types (§3.2)

struct Vector3 {
    var x: Float
    var y: Float
    var z: Float

    # No constructor written. A struct is immutable, so its fields could never be
    # given values without one — the compiler supplies it from the fields above, in
    # the order they are declared: Vector3(x, y, z).

    var length_squared: Float {
        get { return self.x * self.x + self.y * self.y + self.z * self.z }
    }

    # Building a new one is how you "change" a struct.
    func with_x(x: Float): Vector3 {
        return Vector3(x, self.y, self.z)
    }

    static func zero(): Vector3 {
        return Vector3(0.0, 0.0, 0.0)
    }
}

var a = Vector3(1.0, 2.0, 3.0)
print("a = (#{a.x}, #{a.y}, #{a.z})")
print("|a|^2 = #{a.length_squared}")

var b = a.with_x(10.0)
print("b = (#{b.x}, #{b.y}, #{b.z})")
print("a is unchanged: (#{a.x}, #{a.y}, #{a.z})")
print("zero = (#{Vector3.zero().x}, #{Vector3.zero().y}, #{Vector3.zero().z})")
