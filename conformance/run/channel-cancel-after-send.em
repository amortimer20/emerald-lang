# A parked sender whose value was taken has sent it: cancelling it before it
# resumes does not make that send raise. The cancellation arrives at its next
# suspension point (15.13).
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const sender = tasks.start { =>
        numbers.send(7)
        print("sender: send returned")
        Tasks.yield()
        print("unexpected: no cancellation")
    }
    Tasks.yield()
    print("main received: #{numbers.receive()}")
    sender.cancel()
    try {
        sender.result()
    }
    catch error: CancelledError {
        print("sender then: #{error.message}")
    }
}
