Tasks.run { tasks =>
    const queued = tasks.start { => 1 }
    queued.wait(Duration(seconds: -1))
}
