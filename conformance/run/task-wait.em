Tasks.run { tasks =>
    const slow = tasks.start { =>
        Program.sleep(Duration(milliseconds: 10))
        return 42
    }
    print(slow.wait(timeout: Duration(milliseconds: 1)))
    print(slow.result())
    print(slow.wait(Duration()))
}

Tasks.run { tasks =>
    const queued = tasks.start { => 7 }
    print(queued.wait(Duration()))
    print(queued.result())
}
