# Two tasks read lines concurrently; one is cancelled while waiting.
Tasks.run { tasks =>
    const first = tasks.start { => input() }
    const second = tasks.start { => input() }
    Tasks.yield()
    first.cancel()
    try {
        first.result()
    }
    catch error: CancelledError {
        print("first cancelled")
    }
    print("second: #{second.result()}")
}
print("third: #{input()}")
