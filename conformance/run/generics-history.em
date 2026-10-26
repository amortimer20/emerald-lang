class History[T] {
    var current: T
    var _undo: List[T] = []

    constructor(start: T) {
        self.current = start
    }

    func record(state: T) {
        self._undo.append(self.current)
        self.current = state
    }

    func undo() {
        return if self._undo.empty?()
        self.current = self._undo.remove_last()
    }
}

const text = History("")
text.record("Hello")
text.record("Hello, world")
text.undo()
print(text.current)
print(text.current.count)
