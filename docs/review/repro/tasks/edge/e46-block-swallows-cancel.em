# The group block catches the cancellation a failing child caused; the group must still raise.
try {
    const value = Tasks.run { tasks =>
        const failing = tasks.start { =>
            Tasks.yield()
            raise AssertionError("child failed")
        }
        var outcome = 0
        try {
            Program.sleep(Duration(seconds: 30))
        }
        catch error: CancelledError {
            outcome = 1
        }
        print("cancelled done? #{failing.done?()}")
        return outcome
    }
    print("group returned #{value}")
}
catch error: AssertionError {
    print("group raised: #{error.message}")
}
