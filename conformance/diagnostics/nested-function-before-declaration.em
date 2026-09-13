func early() {
    show()
    var x = 1
    func show() {
        print(x)
    }
}

func unset() {
    var y: Int
    later()
    y = 2
    later()
    func later() {
        first()
    }
    func first() {
        print(y)
    }
}

func too_late() {
    func peek() {
        print(z)
    }
    var z = 3
}

func loops() {
    func go(k: Int) {
        return go(k)
    }
}

func twice() {
    var name = 1
    func name() {
    }
}

