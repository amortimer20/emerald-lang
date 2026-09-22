# One symbol may have several disjoint right-hand registrations. Selection is
# static, but the selected method still uses ordinary virtual dispatch.
struct Vector {
    const x: Float
}

struct Matrix {
    const scale: Float

    @operator("*")
    func multiply(other: Self): Self {
        return Matrix(self.scale * other.scale)
    }

    @operator("*")
    func transform(vector: Vector): Vector {
        return Vector(self.scale * vector.x)
    }

    @operator("*")
    func scaled_by(factor: Float): Matrix {
        return Matrix(self.scale * factor)
    }
}

print((Matrix(3.0) * Matrix(2.0)).scale)
print((Matrix(3.0) * Vector(4.0)).x)
print((Matrix(3.0) * 2).scale)

class Animal {
    @operator("*")
    func times(count: Int): Animal {
        return Animal()
    }

    func kind(): String {
        return "animal"
    }
}

class Dog extends Animal {
    constructor() {
        super()
    }

    @override
    func times(count: Int): Animal {
        return Dog()
    }

    @override
    func kind(): String {
        return "dog"
    }
}

const animal: Animal = Dog()
print((animal * 2).kind())

var matrices = [Matrix(2.0)]
var index_calls = 0
func first_index(): Int {
    index_calls += 1
    return 0
}
matrices[first_index()] *= 3
print(matrices[0].scale, index_calls)
