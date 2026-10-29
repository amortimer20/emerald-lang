# 64 live tasks all sleeping on the timer at once, 20 rounds.
var total = 0
for round in 0..<20 {
    total += Tasks.run { tasks =>
        var pending: List[Task[Int]] = []
        for i in 0..<64 {
            pending.append(tasks.start { =>
                Program.sleep(Duration(milliseconds: i % 4))
                return i
            })
        }
        var sum = 0
        for task in pending {
            sum += task.result()
        }
        return sum
    }
}
print(total)
