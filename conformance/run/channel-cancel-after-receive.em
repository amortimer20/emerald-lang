# A message handed to a parked receiver is committed: cancelling the receiver
# before it resumes does not lose it. The receiver gets the value, and the
# cancellation arrives at its next suspension point (15.13).
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const receiver = tasks.start { =>
        const value = numbers.receive()
        print("receiver got #{value}")
        Tasks.yield()
        print("unexpected: no cancellation")
    }
    Tasks.yield()
    numbers.send(42)
    receiver.cancel()
    try {
        receiver.result()
    }
    catch error: CancelledError {
        print("receiver then: #{error.message}")
    }
}
const buffered: Channel[Int] = Channel(capacity: 4)
Tasks.run { tasks =>
    const receiver = tasks.start { => buffered.receive() }
    Tasks.yield()
    buffered.send(43)
    receiver.cancel()
    print("buffered receiver got #{receiver.result()}")
    buffered.close()
    print("left in channel: #{buffered.receive()}")
}
