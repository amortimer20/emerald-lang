# Section 15.13: `done?()` checks without waiting, and failure and cancellation count
# as completion.
Tasks.run { tasks =>
    const failing = tasks.start { =>
        raise Error("broken")
    }
    const sleeper = tasks.start { =>
        Tasks.yield()
        return 1
    }
    print(sleeper.done?())
    sleeper.cancel()
    try {
        sleeper.result()
    }
    catch error: CancelledError {
        print("cancelled")
    }
    print(sleeper.done?())
    try {
        failing.result()
    }
    catch error {
        print(error.message)
    }
    print(failing.done?())
}
