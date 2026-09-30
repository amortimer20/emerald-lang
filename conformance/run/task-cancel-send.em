const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const sender = tasks.start { =>
        try {
            numbers.send(1)
        }
        finally {
            print("sender cleanup")
        }
    }
    Tasks.yield()
    sender.cancel()
    const next = tasks.start { => numbers.send(2) }
    assert numbers.receive() == 2
    next.result()
}
print("no lost message")
