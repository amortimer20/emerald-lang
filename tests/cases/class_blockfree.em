# The whole file is the class body — no braces, no nesting level (§3.3).
class Counter

var value: Int = 0
var _step: Int = 1

constructor(step: Int) {
    self._step = step
}

func bump() {
    self.value += self._step
}
