Tasks.run { tasks =>
    var pending: List[Task[Int]] = []
    for i in 0..<64 {
        pending.append(tasks.start { => i })
    }
    try {
        tasks.start { => 64 }
    }
    catch error: RuntimeError {
        print(error.message)
    }
    var total = 0
    for task in pending {
        total += task.result()
    }
    print(total)
    print(tasks.start { => 99 }.result())
}
