Tasks.run { tasks =>
    const messages: Channel[Task[Int]] = Channel(capacity: 1)
    const job = tasks.start { => 7 }
    messages.send(job)
    const received = messages.receive()
    if received != nothing {
        print(received.result())
    }
}
