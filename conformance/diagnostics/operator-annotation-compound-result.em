struct Vector {
    const x: Float
}

struct Matrix {
    @operator("*")
    func transform(vector: Vector): Vector {
        return vector
    }
}

var matrix = Matrix()
matrix *= Vector(1.0)
