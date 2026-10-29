# Uncaught deadlock of a two-channel cycle: the diagnostic should name both waits.
const left: Channel[Int] = Channel()
const right: Channel[Int] = Channel()
Tasks.run { tasks =>
    tasks.start { =>
        left.receive()
        right.send(1)
    }
    tasks.start { =>
        right.receive()
        left.send(1)
    }
}
