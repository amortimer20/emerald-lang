# Run with a held-open stdin pipe to exercise an actually blocked host read.
# The CLI regression driver also supplies a line only after the error was caught.
const ready: Channel[Int] = Channel(capacity: 1)
try {
    Tasks.run { tasks =>
        tasks.start { =>
            try {
                ready.send(1)
                input()
            }
            finally {
                print("input cleanup")
            }
        }
        tasks.start { =>
            ready.receive()
            raise AssertionError("first failure")
        }
    }
}
catch error: AssertionError {
    print(error.message)
}
if Program.arguments.count > 0 {
    print(input())
}
print("finished")
