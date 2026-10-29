Tasks.run { tasks =>
    const t = tasks.start { => Program.sleep(Duration(milliseconds: 20)) }
    print(t.wait(timeout: Duration(days: 100000000000)))
}
