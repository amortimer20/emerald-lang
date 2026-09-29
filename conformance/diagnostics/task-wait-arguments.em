Tasks.run { tasks =>
    const task = tasks.start { => 1 }
    task.wait(1)
    task.wait(delay: Duration())
    task.wait()
}
