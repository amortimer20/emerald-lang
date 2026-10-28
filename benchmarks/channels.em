# Tasks and channels: producers and a consumer passing values.

const numbers: Channel[Int] = Channel(capacity: 16)
Tasks.run { tasks =>
    for producer in 0..<4 {
        tasks.start { =>
            for n in 0..<100000 {
                numbers.send(n + producer)
            }
        }
    }
    const total = tasks.start { =>
        var sum = 0
        for _ in 0..<400000 {
            sum += numbers.receive().or(0)
        }
        return sum
    }
    print(total.result())
}
