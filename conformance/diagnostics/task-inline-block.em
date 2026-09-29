func work(): Int {
    return 7
}

const stored = { => work() }

Tasks.run { tasks =>
    tasks.start(stored)
    tasks.start(work)
}
