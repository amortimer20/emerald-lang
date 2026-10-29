# 63 tasks blocked on every kind of wait, cancelled together, 20 rounds.
const never: Channel[Int] = Channel()
const full: Channel[Int] = Channel(capacity: 1)
full.send(0)
var cleaned = 0
for round in 0..<20 {
    Tasks.run { tasks =>
        const anchor = tasks.start { => Program.sleep(Duration(seconds: 30)) }
        var pending: List[Task[Nothing]] = []
        for i in 0..<62 {
            pending.append(tasks.start { =>
                const kind = i % 5
                if kind == 0 {
                    never.receive()
                } else if kind == 1 {
                    never.send(i)
                } else if kind == 2 {
                    full.send(i)
                } else if kind == 3 {
                    Program.sleep(Duration(seconds: 30))
                } else {
                    anchor.result()
                }
            })
        }
        Tasks.yield()
        for task in pending {
            task.cancel()
        }
        anchor.cancel()
        var cancelled = 0
        for task in pending {
            try {
                task.result()
            }
            catch error: CancelledError {
                cancelled += 1
            }
        }
        cleaned += cancelled
    }
}
print(cleaned)
