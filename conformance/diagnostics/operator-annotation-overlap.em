class Animal {
}

class Dog extends Animal {
    constructor() {
        super()
    }
}

struct Matrix {
    const scale: Float

    @operator("*")
    func scale_int(value: Int): Matrix {
        return Matrix(self.scale * value)
    }

    @operator("*")
    func scale_float(value: Float): Matrix {
        return Matrix(self.scale * value)
    }

    @operator("+")
    func add_animal(value: Animal): Matrix {
        return self
    }

    @operator("+")
    func add_dog(value: Dog): Matrix {
        return self
    }
}
