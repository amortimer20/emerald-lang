# 5,000 tasks, at most 64 live at once, communicating through a buffered channel.
var total = 0
for batch in 0..<80 {
    total += Tasks.run { tasks =>
        const results: Channel[Int] = Channel(capacity: 8)
        var started: List[Task[Nothing]] = []
        for i in 0..<63 {
            const n = batch * 63 + i
            started.append(tasks.start { => results.send(n) })
        }
        var sum = 0
        for i in 0..<63 {
            sum += results.receive().or(0)
        }
        return sum
    }
}
print(total)
