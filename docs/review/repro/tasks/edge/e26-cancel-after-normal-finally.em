# Cancellation requested during a finally that ran normally is noticed at the next wait.
Tasks.run { tasks =>
    const t = tasks.start { =>
        try {
            print("body")
        }
        finally {
            Program.sleep(Duration(milliseconds: 50))
            print("cleanup done")
        }
        Program.sleep(Duration(seconds: 30))
        print("unexpected: sleep completed")
    }
    Tasks.yield()
    t.cancel()
    try {
        t.result()
    }
    catch error: CancelledError {
        print("t: #{error.message}")
    }
}
print("finished")
