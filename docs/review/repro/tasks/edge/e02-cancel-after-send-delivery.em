# A sender is parked on a rendezvous; main receives (taking its value), then cancels it
# before it resumes. The value was delivered, yet the sender may see CancelledError.
const numbers: Channel[Int] = Channel()
Tasks.run { tasks =>
    const sender = tasks.start { =>
        numbers.send(7)
        print("sender: send returned")
    }
    Tasks.yield()
    print("main received: #{numbers.receive()}")
    sender.cancel()
    try {
        sender.result()
        print("sender finished")
    }
    catch error: CancelledError {
        print("sender cancelled after its value was delivered")
    }
}
