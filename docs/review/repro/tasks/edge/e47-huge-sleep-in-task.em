# A very long sleep inside a task, then cancelled.
Tasks.run { tasks =>
    const t = tasks.start { => Program.sleep(Duration(days: 100000000000)) }
    Tasks.yield()
    print("started")
    t.cancel()
    try {
        t.result()
    }
    catch error: CancelledError {
        print("cancelled")
    }
}
