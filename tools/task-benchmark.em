# Measure one-task groups without retaining 10,000 live OS stacks at once.
const count = if Program.arguments.count == 0 then 1000 else Program.arguments[0].to_int()
var total = 0
for i in 0..<count {
    total += Tasks.run { tasks =>
        const task = tasks.start { => i }
        return task.result()
    }
}
print(total)
