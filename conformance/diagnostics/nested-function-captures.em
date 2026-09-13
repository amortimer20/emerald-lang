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

func loops() {
    func go(k: Int) {
        return go(k)
    }
}

func maybe(flag: Bool) {
    var text: String? = nothing
    if flag {
        text = "set"
    }
    if text != nothing {
        func shout(): String {
            return text.upper()
        }
    }
}
