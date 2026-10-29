const never: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        tasks.start { =>
            try {
                never.receive()
            }
            finally {
                print("receiver cleanup")
            }
        }
        tasks.start { =>
            try {
                never.send(1)
            }
            catch error: RuntimeError {
                print("unexpected RuntimeError: #{error.message}")
            }
            finally {
                print("sender cleanup")
            }
        }
        Tasks.yield()
        raise AssertionError("block failed")
    }
}
catch error: AssertionError {
    print("caught #{error.message}")
}
