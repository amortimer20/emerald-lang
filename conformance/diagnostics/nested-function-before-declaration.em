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


# Unpacking into a variable counts as using it, as a plain assignment does.
func unpack_early() {
    reset()
    var a = 1
    func reset() {
        (a, _) = (0, 0)
    }
}
