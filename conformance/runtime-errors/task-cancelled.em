const task = Tasks.run { tasks =>
    const child = tasks.start { =>
        Program.sleep(Duration(seconds: 60))
        return 1
    }
    Tasks.yield()
    child.cancel()
    return child
}
task.result()
