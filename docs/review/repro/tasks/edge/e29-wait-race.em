# Timed waits that race their target's completion: each must return a Bool and
# result() must then succeed. Counts are timing dependent; only crashes matter.
var finished = 0
for round in 0..<200 {
    Tasks.run { tasks =>
        const t = tasks.start { =>
            Program.sleep(Duration(milliseconds: 1))
            return round
        }
        if t.wait(timeout: Duration(milliseconds: 1)) {
            finished += 1
        }
        assert t.result() == round
    }
}
print("ok")
