var hooks: List[func()] = []

struct Loop {
    var n: Int = 0
    func go() {
        self.n += 1
        hooks[0]()
    }
}
var looper = Loop()
hooks.append(looper.go)
hooks[0]()
