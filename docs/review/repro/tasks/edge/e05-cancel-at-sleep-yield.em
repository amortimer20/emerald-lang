# Cancel at Tasks.yield inside a loop, and at a sleep.
Tasks.run { tasks =>
    const spinner = tasks.start { =>
        var count = 0
        try {
            while true {
                count += 1
                Tasks.yield()
            }
        }
        finally {
            print("spinner cleanup")
        }
    }
    const sleeper = tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            print("sleeper cleanup")
        }
    }
    Tasks.yield()
    Tasks.yield()
    spinner.cancel()
    sleeper.cancel()
    for task in [spinner, sleeper] {
        try {
            task.result()
        }
        catch error: CancelledError {
            print("cancelled")
        }
    }
}
print("finished")
