# A receiver is parked; main sends (delivered straight to the receiver), then cancels it
# before it resumes. The send returned normally, so the message was committed.
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const receiver = tasks.start { => numbers.receive() }
    Tasks.yield()
    numbers.send(42)
    receiver.cancel()
    try {
        print("received: #{receiver.result()}")
    }
    catch error: CancelledError {
        print("receiver cancelled; message 42 was sent but nobody received it")
    }
}
