# Cleanup itself blocks on a channel nobody will ever feed.
const never: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        const t = tasks.start { =>
            try {
                Program.sleep(Duration(seconds: 30))
            }
            finally {
                print("cleanup waiting")
                never.receive()
                print("cleanup unexpectedly continued")
            }
        }
        Tasks.yield()
        t.cancel()
    }
}
catch error: DeadlockError {
    print("caught deadlock: #{error.message}")
}
print("finished")
