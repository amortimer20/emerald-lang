const cleanup: Channel[Int] = Channel()
Tasks.run { tasks =>
    const task = tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 60))
        }
        finally {
            cleanup.send(1)
            cleanup.send(2)
            Program.sleep(Duration(milliseconds: 1))
            print("cleanup waited")
        }
    }
    Tasks.yield()
    task.cancel()
    assert cleanup.receive() == 1
    task.cancel()
    assert cleanup.receive() == 2
}
print("finished")
