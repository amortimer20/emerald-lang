var shared = 0
Tasks.run { tasks =>
    tasks.start { =>
        shared += 1
    }
}
