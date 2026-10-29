# Two channels, two tasks, each receives before sending: every task blocked.
const left: Channel[Int] = Channel()
const right: Channel[Int] = Channel()
try {
    Tasks.run { tasks =>
        tasks.start { =>
            left.receive()
            right.send(1)
        }
        tasks.start { =>
            right.receive()
            left.send(1)
        }
    }
}
catch error: DeadlockError {
    print("caught: #{error.message}")
}
print("finished")
