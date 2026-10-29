# Buffered variant of e01: an empty buffered channel hands a send straight to a parked receiver.
const numbers: Channel[Int] = Channel(capacity: 4)
Tasks.run { tasks =>
    const receiver = tasks.start { => numbers.receive() }
    Tasks.yield()
    numbers.send(42)
    receiver.cancel()
    try {
        print("received: #{receiver.result()}")
    }
    catch error: CancelledError {
        print("receiver cancelled")
    }
    numbers.close()
    print("left in channel: #{numbers.receive()}")
}
