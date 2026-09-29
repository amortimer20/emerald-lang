class Slot {
    var current: Task[Int]? = nothing
}

const slot = Slot()
Tasks.run { tasks =>
    const fallback = tasks.start { => 0 }
    const waiting = tasks.start { => slot.current.or(fallback).result() }
    slot.current = waiting
    waiting.result()
}
