const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const waiting = tasks.start { => numbers.receive() }
    waiting.result()
}
