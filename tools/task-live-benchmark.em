# Measure the live-task cap: all tasks stay queued until the group first waits.
const count = if Program.arguments.count == 0 then 64 else Program.arguments[0].to_int()
Tasks.run { tasks =>
    var pending: List[Task[Int]] = []
    for i in 0..<count {
        pending.append(tasks.start { => i })
    }
    print("started: #{pending.count}")
    var total = 0
    for task in pending {
        total += task.result()
    }
    print(total)
}
