func work(n: Int): Int {
    var total = 0
    for i in 0..<400 {
        const item = [n, i]
        const cycle = { => item[0] + item[1] }
        total += cycle()
    }
    return total
}

Tasks.run { tasks =>
    var pending: List[Task[Int]] = []
    for n in 0..<32 {
        pending.append(tasks.start { => work(n) })
    }
    var total = 0
    for task in pending {
        total += task.result()
    }
    print(total)
}
