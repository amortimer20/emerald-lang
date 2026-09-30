# Demonstrates why I/O tasks print their results outside the tasks for fixed order.
const path = "emerald-task-io-order-probe.txt"
File.write(path, "x".repeat(1000000))
try {
    Tasks.run { tasks =>
        tasks.start { =>
            File.read(path)
            print("a")
        }
        tasks.start { =>
            File.read(path)
            print("b")
        }
    }
}
finally {
    File.delete(path)
}
