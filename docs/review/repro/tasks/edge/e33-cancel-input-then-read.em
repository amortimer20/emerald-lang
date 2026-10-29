# Run with a held-open stdin pipe that writes "late" after a delay.
# The cancelled read's line is delivered to the next input call.
Tasks.run { tasks =>
    const reader = tasks.start { => input() }
    Tasks.yield()
    reader.cancel()
    try {
        reader.result()
    }
    catch error: CancelledError {
        print("cancelled read")
    }
}
print("next: #{input()}")
