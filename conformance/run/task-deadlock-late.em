class Slot {
    var current: Task[Int]? = nothing
}
const slot = Slot()
try {
    Tasks.run { tasks =>
        const fallback = tasks.start { => 1 }
        const waiting = tasks.start { => slot.current.or(fallback).result() }
        slot.current = waiting
        tasks.start { => 99 }
    }
}
catch error: DeadlockError {
    print(error.message)
}
