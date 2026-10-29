# exit() inside a task whose caller catches every Error: exit is not an error (15.2).
Tasks.run { tasks =>
    const t = tasks.start { => exit(8) }
    try {
        t.result()
    }
    catch error: Error {
        print("caught #{error.message}")
    }
    print("unexpected: still running")
}
