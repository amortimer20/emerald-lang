Tasks.run { tasks =>
    const task = tasks.start { => 42 }
    task./*cursor*/
}
