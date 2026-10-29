# Cleanup blocks forever after cancellation; uncaught.
const never: Channel[Int] = Channel()
Tasks.run { tasks =>
    const t = tasks.start { =>
        try {
            Program.sleep(Duration(seconds: 30))
        }
        finally {
            never.receive()
        }
    }
    Tasks.yield()
    t.cancel()
}
